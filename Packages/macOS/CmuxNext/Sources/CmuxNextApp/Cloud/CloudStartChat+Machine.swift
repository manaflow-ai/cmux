import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Which Cloud machine a `cloud.startChat` send runs on (Leo, 2026-10-30: "like the initial 0 to 1
/// chat auto it sends to cloud"). Never the team's first connected machine, which on a shared
/// account is often someone's busy lane VM: a machine this person owns that is free (no chat open
/// on it, or one named for chats, ``chatsName``), else a new one named for chats. Lane-pool VMs
/// (`fs-lane-N`, `lane-vm-N`) are never picked. A retry of the same send stays on the machine its
/// first try took (``Destinations``), so it never opens a second chat with the prompt elsewhere.
extension CloudStartChat {
    /// One Cloud machine as the pick reads it.
    struct Candidate: Equatable, Sendable {
        var id: String
        var title: String
        var slug: String?
        /// ``CloudMachine/createdBy``: the person who created it, when the server says.
        var createdBy: String?
        var status: CloudMachine.Status
        var pauseReason: CloudMachine.PauseReason?
        var connected: Bool
        /// Chat tabs open on it; nil when its store is not read (not connected).
        var chats: Int?
    }

    /// The name a machine made for chats gets, and how a machine is marked as one for chats.
    static let chatsName = "cloud-chats"

    static func isMarkedForChats(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == chatsName || (name.hasPrefix(chatsName + "-") && name.dropFirst(chatsName.count + 1).allSatisfy(\.isNumber))
    }

    /// A lane-pool VM's name: `fs-lane-N` or `lane-vm-N` (leo-workspace machines/lane-vms.md).
    static func isLanePool(_ name: String) -> Bool {
        let name = name.lowercased()
        for prefix in ["fs-lane-", "lane-vm-"] where name.hasPrefix(prefix) {
            let number = name.dropFirst(prefix.count)
            if !number.isEmpty, number.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The machine a first send takes, by id; nil: make one (``chatsName``). Only this person's
    /// (`user`; a machine the server names no creator for counts when an earlier send of this app
    /// ran on it, `used`), never a lane-pool VM, and only one that can take work now or after an
    /// idle resume. Among those: one marked for chats first, then a free one (connected with no
    /// chat open, or paused by the idle timer, which pauses only an idle machine); connected first.
    static func pick(_ candidates: [Candidate], user: String?, used: Set<String>) -> String? {
        guard let user else { return nil }
        func mine(_ machine: Candidate) -> Bool {
            if let creator = machine.createdBy { return creator == user }
            return used.contains(machine.id)
        }
        func free(_ machine: Candidate) -> Bool {
            machine.connected ? machine.chats == 0 : (machine.status == .paused && machine.pauseReason == .idle)
        }
        let eligible = candidates.filter { machine in
            mine(machine) && !isLanePool(machine.title) && !(machine.slug.map(isLanePool) ?? false)
                && (machine.connected || machine.status.isLive || (machine.status == .paused && machine.pauseReason == .idle))
        }
        let marked = { (machine: Candidate) in isMarkedForChats(machine.title) || (machine.slug.map(isMarkedForChats) ?? false) }
        let ranked = eligible.filter { marked($0) || free($0) }.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if marked(x) != marked(y) { return marked(x) }
            if x.connected != y.connected { return x.connected }
            return a.offset < b.offset
        }
        return ranked.first?.element.id
    }

    /// The name a new machine for chats gets: ``chatsName``, else `cloud-chats-N`, unique among `taken`.
    static func newMachineName(taken: some Sequence<String>) -> String {
        CloudMachine.defaultName(taken: taken, base: chatsName, numbered: { "\(chatsName)-\($0)" })
    }

    /// The machine each recent send (its ``AgentPaneCloudStart/key``) ran on, newest last, at most
    /// ``limit``: a retry of a send names it, so the retry's tab key (which only that machine's
    /// daemon knows) gets back the tab its first try opened, never a second chat elsewhere.
    /// Kept in the app's user defaults (``CloudMoveSetup/ledger``), so a relaunch keeps it; in
    /// memory only without them (tests).
    @MainActor
    final class Destinations {
        static let limit = 64
        static let defaultsKey = "cmux.cloud.startChatDestinations"

        private struct Entry: Codable, Equatable {
            var key: String
            var machineID: String
            /// The chat's folder on that machine once the send's copy finished there: a retry
            /// opens its chat there without copying again, which would overwrite what the chat
            /// already changed (`cmux link sync push` rewrites every file the machine changed).
            var copiedChat: String?
            /// The folder under the work root this send's copy goes to on that machine, kept from
            /// before the copy starts (``place(for:on:)``).
            var place: String?
        }

        var defaults: @MainActor () -> UserDefaults? = { nil }
        private var memory: [Entry] = []

        init() {}

        /// The machine the send `key` ran on, if it ran.
        func machine(for key: String) -> String? {
            let key = key.lowercased()
            return entries().last { $0.key == key }?.machineID
        }

        /// Every machine a kept send ran on.
        var machines: Set<String> { Set(entries().map(\.machineID)) }

        /// Pins the send `key` to `machineID` (before anything runs there). A pin to the same
        /// machine keeps its finished copy.
        func record(_ machineID: String, for key: String) {
            let key = key.lowercased()
            let all = entries()
            let same = all.last { $0.key == key && $0.machineID == machineID }
            var kept = all.filter { $0.key != key }
            kept.append(Entry(key: key, machineID: machineID, copiedChat: same?.copiedChat, place: same?.place))
            save(Array(kept.suffix(Self.limit)))
        }

        /// The folder under the machine's work root the send `key`'s copy goes to on `machineID`:
        /// the one kept for it, else a new one (`fresh`, under ``AgentPaneCloudStart/remotePlace``),
        /// kept now, before anything is copied. A retry finds its own copy's folder; a retry whose
        /// record is gone (older than ``limit`` sends, another machine) gets a new folder, so its
        /// copy never writes over a chat that already started in the old one (`cmux link sync push`
        /// rewrites every file the machine changed).
        func place(for key: String, on machineID: String, fresh: () -> String) -> String {
            let lowered = key.lowercased()
            let all = entries()
            if let kept = all.last(where: { $0.key == lowered && $0.machineID == machineID })?.place { return kept }
            let place = fresh()
            var kept = all.filter { $0.key != lowered }
            kept.append(Entry(key: lowered, machineID: machineID, copiedChat: nil, place: place))
            save(Array(kept.suffix(Self.limit)))
            return place
        }

        /// The chat's folder on `machineID` when the send `key`'s copy finished there.
        func copiedChat(for key: String, on machineID: String) -> String? {
            let key = key.lowercased()
            return entries().last { $0.key == key && $0.machineID == machineID }?.copiedChat
        }

        /// The send `key`'s copy finished on `machineID`, its chat's folder there `chat`.
        func recordCopy(_ chat: String, for key: String, on machineID: String) {
            let key = key.lowercased()
            let all = entries()
            let place = all.last { $0.key == key && $0.machineID == machineID }?.place
            var kept = all.filter { $0.key != key }
            kept.append(Entry(key: key, machineID: machineID, copiedChat: chat, place: place))
            save(Array(kept.suffix(Self.limit)))
        }

        /// Drops the send `key`'s pin (its machine is gone).
        func forget(_ key: String) {
            let key = key.lowercased()
            let all = entries()
            let kept = all.filter { $0.key != key }
            if kept.count != all.count { save(kept) }
        }

        private func entries() -> [Entry] {
            guard let defaults = defaults() else { return memory }
            guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }

        private func save(_ all: [Entry]) {
            guard let defaults = defaults() else {
                memory = all
                return
            }
            defaults.set(try? JSONEncoder().encode(all), forKey: Self.defaultsKey)
        }
    }

    /// The create of the machine for the send `start`: sized for the chat, under the send's own
    /// idempotency key (``AgentPaneCloudStart/createKey``), so a retry after a create whose answer
    /// was lost gets the same machine from the server, never a second paid VM.
    static func createRequest(for start: AgentPaneCloudStart, sizedFor pick: CloudWorkPick?) -> CloudMachineRequest {
        var request = CloudChatPick.request(sizedFor: pick)
        request.idempotencyKey = start.createKey
        return request
    }

    /// Where a send goes: a machine by id, or a new one for chats.
    enum Destination: Equatable {
        case machine(String)
        case new
    }

    /// Where the send `key` goes: the machine its first try took while that machine exists
    /// (`exists` nil: the list is not loaded yet, so it is kept), else ``pick(_:user:used:)``.
    /// Drops a pin to a machine that is gone, which holds no tab of this send.
    static func destination(for key: String, destinations: Destinations, candidates: [Candidate], user: String?,
                            exists: (String) -> Bool?) -> Destination {
        if let pinned = destinations.machine(for: key) {
            if exists(pinned) != false { return .machine(pinned) }
            destinations.forget(key)
        }
        return pick(candidates, user: user, used: destinations.machines).map(Destination.machine) ?? .new
    }

    /// The machine for the send `start`, connected (``destination(for:destinations:candidates:user:exists:)``);
    /// a new one is named for chats and sized for the chat (`pick`). Pins the send to it before
    /// anything runs there, so a retry of the send names it.
    func machine(for start: AgentPaneCloudStart, invocation: ActionInvocation,
                 pick: () async -> CloudWorkPick?) async throws -> CloudMachineSession {
        let destinations = services.cloud.startChatDestinations, machines = services.machines, cloud = services.cloud
        let candidates = machines.cloud.map { session in
            let connected = session.daemon.connection != nil
            let chats = connected
                ? session.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.agentSession != nil }.count
                : nil
            return Candidate(id: session.machineID, title: session.machine.title, slug: session.machine.slug, createdBy: session.machine.createdBy,
                             status: session.machine.status, pauseReason: session.machine.pauseReason, connected: connected, chats: chats)
        }
        let destination = Self.destination(for: start.key, destinations: destinations, candidates: candidates, user: cloud.auth.user?.id) { id in
            cloud.hasLoadedMachines ? machines.session(id) != nil : nil
        }
        var invocation = invocation
        switch destination {
        case .machine(let id):
            destinations.record(id, for: start.key)
            invocation.arguments["machine"] = .string(id)
        case .new:
            let created = try await cloud.createMachine(name: Self.newMachineName(taken: machines.cloud.map(\.machine.title)),
                                                        startedByPerson: invocation.origin == .user,
                                                        request: Self.createRequest(for: start, sizedFor: await pick()))
            destinations.record(created.machineID, for: start.key)
            invocation.arguments["machine"] = .string(created.machineID)
        }
        return try await CloudMove(services: services).machine(invocation, pick: pick)
    }
}
