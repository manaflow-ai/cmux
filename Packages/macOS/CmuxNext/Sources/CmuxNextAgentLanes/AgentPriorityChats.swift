public import CmuxNextAgentActivity
public import CmuxNextSidebar
public import Foundation
import os

/// The chats the Priority view ranks (every lane of this Mac's acpmux and the Chief home's, and
/// every agent chat on the other machines the app shows: ``SidebarPriorityMachine``) and what a
/// row does to one: mark read, pin, snooze, archive. One per app: the registered row
/// actions write through it, so a hover button, the row's menu and the palette change the same
/// marks (`AgentPriorityMarks`). Each returns false when no store lists the chat.
@MainActor
public final class AgentPriorityChats {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.priority")

    /// The machines the rows name, read inside an observation scope.
    public struct Machines {
        /// The other machines whose daemon trees list agent chats.
        public var remote: @MainActor () -> [SidebarPriorityMachine]
        /// The display name of the machine an acpmux peer is; nil when none matches (the row
        /// then shows the peer's name).
        public var peer: @MainActor (String) -> String?
        /// This Mac's tag: its name while `sidebar.showLocalMachine` is on, else nil.
        public var local: @MainActor () -> String?

        public init(remote: @escaping @MainActor () -> [SidebarPriorityMachine], peer: @escaping @MainActor (String) -> String?,
                    local: @escaping @MainActor () -> String?) {
            self.remote = remote
            self.peer = peer
            self.local = local
        }

        /// No other machine, every peer by its own name, this Mac untagged.
        public static var none: Self { Self(remote: { [] }, peer: { _ in nil }, local: { nil }) }
    }

    public let marks: AgentPriorityMarks
    public let stores: [AgentLaneStore]
    /// Set by the App once its machines exist (the app's chats outlive no window).
    public var machines: Machines
    private let ranking = AgentPriorityRanking()
    /// `_acpmux/archive` for a session on the acpmux socket at the first argument.
    private let archiveRequest: @Sendable (_ socketPath: String, _ sessionId: String) async throws -> Void
    /// Whether a chat's pull request checks fail (Red CI), by default the session tree feed's answer.
    private let checksFailing: @MainActor (AgentActivityLane) -> Bool

    public init(marks: AgentPriorityMarks = .shared, stores: [AgentLaneStore] = [.shared, .chief], machines: Machines = .none,
                checksFailing: (@MainActor (AgentActivityLane) -> Bool)? = nil,
                archive: @escaping @Sendable (_ socketPath: String, _ sessionId: String) async throws -> Void) {
        self.marks = marks
        self.stores = stores
        self.machines = machines
        self.checksFailing = checksFailing ?? { SidebarSessionTreeFeed.shared.checksFailing($0) }
        self.archiveRequest = archive
    }

    /// The chats as they are now, built once for everything that reads them at one change (the
    /// rows, the next wake, the prune): every lane, each one's machine tag, the Red CI ones and
    /// the other machines they came from.
    public struct Snapshot {
        public let lanes: [AgentActivityLane]
        let tags: [String: String]
        public let failingChecks: Set<String>
        let machines: [SidebarPriorityMachine]
    }

    /// Every lane of every store, then of every other machine's tree, this Mac's first when an id
    /// repeats (a peer's chat that its machine's tree shows too), and each one's machine tag.
    public func snapshot() -> Snapshot {
        var seen = Set<String>()
        var tags: [String: String] = [:]
        let localTag = machines.local()
        var lanes = stores.flatMap { $0.lanes.values.sorted { $0.id < $1.id } }.filter { seen.insert($0.id).inserted }
        for lane in lanes {
            tags[lane.id] = lane.peer.map { machines.peer($0) ?? $0 } ?? localTag
        }
        let remote = machines.remote()
        for machine in remote {
            for lane in machine.lanes() where seen.insert(lane.id).inserted {
                lanes.append(lane)
                tags[lane.id] = machine.name ?? localTag
            }
        }
        return Snapshot(lanes: lanes, tags: tags, failingChecks: failingChecks, machines: remote)
    }

    /// Every chat the view ranks.
    public var lanes: [AgentActivityLane] { snapshot().lanes }

    /// Every watched store and every other machine's tree is live: `lanes` is every chat, not a
    /// gap, so a chat missing from it may lose its marks.
    public var complete: Bool { complete(machines.remote()) }

    /// `complete` for the machines a `Snapshot` came from.
    public func complete(_ snapshot: Snapshot) -> Bool { complete(snapshot.machines) }

    private func complete(_ remote: [SidebarPriorityMachine]) -> Bool {
        stores.allSatisfy { $0.live || $0.socketPath == nil } && remote.allSatisfy(\.live)
    }

    public func lane(_ id: String) -> AgentActivityLane? {
        stores.lazy.compactMap { $0.lanes[id] }.first ?? lanes.first { $0.id == id }
    }

    /// The id of the tab that shows the chat on the other machine whose row it is (the first
    /// machine whose tree shows it, as `snapshot` takes it); nil when no machine's tree does.
    public func remoteTab(showing id: String) -> String? {
        machines.remote().lazy.compactMap { $0.tab(showing: id) }.first
    }

    /// The chats with a pull request whose checks fail (Red CI). Only this Mac's and the Chief
    /// home's: the session tree reads pull requests from a lane's folder and opened URLs, which
    /// another machine's chat tab does not carry, so a remote row is never Red CI.
    public var failingChecks: Set<String> {
        var seen = Set<String>()
        return Set(stores.flatMap { $0.lanes.values }.filter { seen.insert($0.id).inserted && checksFailing($0) }.map(\.id))
    }

    /// The rows as the Priority view ranks them now, Red CI included and each named by its
    /// machine, so a row's menu and the palette read the state the row shows.
    public func entries(now: Date = Date()) -> [SidebarPriorityEntry] {
        entries(snapshot(), now: now)
    }

    /// The rows of `snapshot`.
    public func entries(_ snapshot: Snapshot, now: Date = Date()) -> [SidebarPriorityEntry] {
        ranking.entries(snapshot.lanes, marks: marks.state, now: now, failingChecks: snapshot.failingChecks) { snapshot.tags[$0.id] }
    }

    /// The chats waiting for the person, in the order Go to Next Agent Needing Input visits them
    /// (``AgentPriorityRanking/needingInput(_:marks:now:)``). Reads each store's waiting index
    /// (``AgentLaneStore/waiting``) and the other machines' tabs with an unread question, never
    /// every lane's row: this runs on the action's own turn and for the menu bar's count. A
    /// session an earlier store lists is that store's, as in ``snapshot()``.
    public func needingInput(now: Date = Date()) -> [AgentActivityLane] {
        var waiting: [AgentActivityLane] = []
        var seen = Set<String>()
        for (index, store) in stores.enumerated() {
            let lanes = store.lanes
            for id in store.waiting.sorted() where !stores[..<index].contains(where: { $0.lanes[id] != nil }) {
                if let lane = lanes[id], seen.insert(id).inserted { waiting.append(lane) }
            }
        }
        for machine in machines.remote() {
            for lane in machine.waitingLanes() where seen.insert(lane.id).inserted
                && !stores.contains(where: { $0.lanes[lane.id] != nil }) {
                waiting.append(lane)
            }
        }
        return AgentPriorityRanking.needingInput(waiting, marks: marks.state, now: now)
    }

    /// The chat's row, nil when the view does not list it (archived, snoozed, idle too long).
    public func entry(_ id: String, now: Date = Date()) -> SidebarPriorityEntry? {
        entries(now: now).first { $0.id == id }
    }

    @discardableResult
    public func markRead(_ id: String) -> Bool {
        guard let lane = lane(id) else { return false }
        marks.markRead(lane)
        return true
    }

    @discardableResult
    public func togglePin(_ id: String) -> Bool {
        guard lane(id) != nil else { return false }
        marks.togglePin(id)
        return true
    }

    @discardableResult
    public func snooze(_ id: String, now: Date = Date()) -> Bool {
        guard let lane = lane(id) else { return false }
        marks.snooze(lane, now: now)
        return true
    }

    /// Hides the chat here at once, then archives it in the acpmux that reports it (this Mac's or
    /// the Chief home's; another machine's chat has no socket here and is not archived). A refusal (a peer's chat this acpmux does not own, a dropped socket)
    /// shows the chat again.
    @discardableResult
    public func archive(_ id: String) -> Bool {
        guard let socketPath = stores.first(where: { $0.lanes[id] != nil })?.socketPath else { return false }
        marks.archive(id)
        let archive = archiveRequest, marks = marks
        // task-owner: one archive request; ends when acpmux answers or its deadline passes
        Task {
            do { try await archive(socketPath, id) } catch {
                Self.logger.error("priority archive failed: \(String(describing: error), privacy: .public)")
                marks.unarchive(id)
            }
        }
        return true
    }
}
