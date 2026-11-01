#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Observation

/// An authenticated directory entry from the paired Mac's current Cloud registry.
public struct CloudChatMachine: Decodable, Hashable, Identifiable, Sendable {
    public let machineID: String
    public let teamID: String
    public let name: String
    public var id: String { teamID + "\u{1}" + machineID }

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id", teamID = "team_id", name
    }
}

/// One Cloud machine's ACP channel over a paired Mac. The existing chat hub
/// owns replay, streaming, prompt IDs and recovery; this only binds its carrier.
@MainActor @Observable
public final class CloudChatRelay {
    public let machine: CloudChatMachine
    public let macID: String
    public private(set) var hub = AcpmuxHub()
    public private(set) var error: String?
    public private(set) var isRetired = false
    @ObservationIgnored private var linkID: ObjectIdentifier?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var binding: Task<Void, Never>?
    @ObservationIgnored private var stores: [String: AgentChatStore] = [:]

    init(machine: CloudChatMachine, macID: String) {
        self.machine = machine
        self.macID = macID
    }

    func bind(_ link: any MacLink, force: Bool = false) {
        guard !isRetired else { return }
        if !force, linkID == ObjectIdentifier(link), binding != nil || hub.isReady { return }
        generation += 1
        let generation = generation
        linkID = ObjectIdentifier(link)
        error = nil
        binding?.cancel()
        binding = Task { [weak self] in
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            let hub = self.hub
            await hub.bind(nil)
            do {
                let channel = try await link.openChannel(service: "cloud-acpmux", args: [
                    "machine_id": machine.machineID, "team_id": machine.teamID,
                ])
                guard self.generation == generation, !Task.isCancelled else {
                    await channel.close(code: "eof", reason: "link replaced")
                    return
                }
                // Files on this VM must never use the relay Mac's file/upload
                // services. Leave macLink unset; ACP still carries chat text.
                await hub.bind(channel)
                guard self.generation == generation else { return }
                if !hub.isReady { error = "Couldn't connect. Try again." }
            } catch {
                guard self.generation == generation else { return }
                self.error = "Couldn't connect. Try again."
            }
            if self.generation == generation { binding = nil }
        }
    }

    func disconnect() {
        generation += 1
        let generation = generation
        linkID = nil
        binding?.cancel()
        binding = nil
        hub.cancelWaiters()
        let hub = self.hub
        Task { [weak self] in
            guard let self, self.generation == generation else { return }
            await hub.bind(nil)
        }
    }

    /// Account/team teardown is permanent, unlike a reconnect. A sheet still
    /// leaving the screen cannot retain or reopen this account's chat stores.
    func retire() {
        disconnect()
        isRetired = true
        stores.removeAll()
        hub = AcpmuxHub()
    }

    /// The exact session listed on this machine, without a local-Mac fallback.
    public func store(sessionID: String) -> AgentChatStore? {
        guard !isRetired, let session = hub.sessions[sessionID], session.peer == nil else { return nil }
        if let store = stores[sessionID] { return store }
        let summary = AgentSessionSummary(
            id: session.id, name: session.name, harness: session.harness, agentName: session.harness,
            cwd: session.cwd, workspaceTitle: machine.name, macName: machine.name,
            status: session.summaryStatus, macID: macID
        )
        let store = AgentChatStore(source: hub.source(sessionID: sessionID, summary: summary))
        stores[sessionID] = store
        return store
    }
}

extension LiveCoordinator {
    /// Directory and ACP calls use the same authenticated pairing lifecycle as
    /// existing Mac chats. A signed-out or replaced coordinator serves nothing.
    private func cloudLink(on macID: String) async throws -> (MacSession, any MacLink) {
        guard !stopped, canLink(macID: macID) else { throw LinkError(code: "offline", message: "Connect your Mac.") }
        touch(macID)
        guard await waitUntil(within: .seconds(20), { [weak self] in
            self?.sessions[macID]?.workspaces.daemon != nil
        }), let session = sessions[macID], !stopped else {
            throw LinkError(code: "offline", message: "Couldn't connect. Try again.")
        }
        let link = try await pairedLink(session)
        guard !stopped, sessions[macID] === session else { throw LinkError(code: "offline", message: "Connect your Mac.") }
        return (session, link)
    }

    public func cloudMachines(on macID: String) async throws -> [CloudChatMachine] {
        let (session, link) = try await cloudLink(on: macID)
        let channel = try await link.openChannel(service: "cloud-directory", args: [:])
        let machines: [CloudChatMachine]
        do {
            machines = try await CloudChatDirectory.read(channel)
        } catch {
            await channel.close(code: "eof", reason: "directory ended")
            throw error
        }
        await channel.close(code: "eof", reason: "directory read")
        guard !stopped, sessions[macID] === session, session.currentLink === link else {
            throw LinkError(code: "offline", message: "Connection changed. Try again.")
        }
        return machines
    }

    public func cloudChats(on macID: String, machine: CloudChatMachine) async throws -> CloudChatRelay {
        let (session, link) = try await cloudLink(on: macID)
        let relay = session.cloudChats[machine.id] ?? CloudChatRelay(machine: machine, macID: macID)
        session.cloudChats[machine.id] = relay
        relay.bind(link, force: true)
        return relay
    }
}

/// A directory is a single JSON document followed by EOF. The deadline closes
/// its channel so a disappeared Mac cannot leave a refresh suspended forever.
public enum CloudChatDirectory {
    struct Reply: Decodable { let machines: [CloudChatMachine] }

    /// Narrows a push to the fresh, authenticated Cloud directory. Cloud's
    /// `team_id` is intentionally matched only with another Cloud directory
    /// entry; it has no relationship to Stack's team UUID.
    public static func scopedMachines(_ machines: [CloudChatMachine], attention: CloudChatAttention?) -> [CloudChatMachine] {
        machines
            .filter { machine in
                attention.map { $0.teamID == machine.teamID && $0.machineID == machine.machineID } ?? true
            }
            .sorted { $0.id < $1.id }
    }

    static func read(_ channel: any LinkChannel) async throws -> [CloudChatMachine] {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [CloudChatMachine].self) { group in
                group.addTask {
                    var bytes = Data()
                    while let chunk = try await channel.receive() {
                        bytes.append(chunk)
                        guard bytes.count <= 4 * 1024 * 1024 else {
                            throw LinkError(code: "directory", message: "Couldn't load Cloud machines.")
                        }
                    }
                    if let error = channel.closedBy, error.code != "eof" { throw error }
                    return try JSONDecoder().decode(Reply.self, from: bytes).machines
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    await channel.close(code: "timeout", reason: "directory timed out")
                    throw LinkError(code: "timeout", message: "Couldn't load Cloud machines. Try again.")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? []
            }
        } onCancel: {
            Task { await channel.close(code: "cancelled", reason: "directory cancelled") }
        }
    }
}
#endif
