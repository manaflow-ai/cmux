public import CmuxNextAgentActivity
public import CmuxNextSidebar
public import Foundation
import os

/// The chats the Priority view ranks (every lane of this Mac's acpmux and the Chief home's) and
/// what a row does to one: mark read, pin, snooze, archive. One per app: the registered row
/// actions write through it, so a hover button, the row's menu and the palette change the same
/// marks (`AgentPriorityMarks`). Each returns false when no store lists the chat.
@MainActor
public final class AgentPriorityChats {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.priority")

    public let marks: AgentPriorityMarks
    public let stores: [AgentLaneStore]
    private let ranking = AgentPriorityRanking()
    /// `_acpmux/archive` for a session on the acpmux socket at the first argument.
    private let archiveRequest: @Sendable (_ socketPath: String, _ sessionId: String) async throws -> Void
    /// Whether a chat's pull request checks fail (Red CI), by default the session tree feed's answer.
    private let checksFailing: @MainActor (AgentActivityLane) -> Bool

    public init(marks: AgentPriorityMarks = .shared, stores: [AgentLaneStore] = [.shared, .chief],
                checksFailing: (@MainActor (AgentActivityLane) -> Bool)? = nil,
                archive: @escaping @Sendable (_ socketPath: String, _ sessionId: String) async throws -> Void) {
        self.marks = marks
        self.stores = stores
        self.checksFailing = checksFailing ?? { SidebarSessionTreeFeed.shared.checksFailing($0) }
        self.archiveRequest = archive
    }

    /// Every lane of every store, this Mac's first when an id repeats.
    public var lanes: [AgentActivityLane] {
        var seen = Set<String>()
        return stores.flatMap { $0.lanes.values.sorted { $0.id < $1.id } }.filter { seen.insert($0.id).inserted }
    }

    public func lane(_ id: String) -> AgentActivityLane? {
        stores.lazy.compactMap { $0.lanes[id] }.first
    }

    /// The chats with a pull request whose checks fail (Red CI).
    public var failingChecks: Set<String> {
        Set(lanes.filter { checksFailing($0) }.map(\.id))
    }

    /// The rows as the Priority view ranks them now, Red CI included, so a row's menu and the
    /// palette read the state the row shows.
    public func entries(now: Date = Date()) -> [SidebarPriorityEntry] {
        ranking.entries(lanes, marks: marks.state, now: now, failingChecks: failingChecks)
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
    /// the Chief home's). A refusal (a peer's chat this acpmux does not own, a dropped socket)
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
