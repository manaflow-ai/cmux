public import Foundation

/// Settled chats (`sidebar.settleFinished`, off by default; leo-workspace design/sidebar.md "Agent workspace identity
/// and organization"). An agent chat whose last turn finished and that the person has read leaves its list's working
/// order for a "Settled (N)" row at the list's end (`SidebarLayout.foldingDone`); a new turn, a question, an unread
/// answer, a failure or a lost agent brings it back by itself, since the rule reads the row's live state each time.
///
/// The rule is Rust's (`cmux-layout-reducer` `settle`, op `sidebar_settle_plan`); this is the app's side of the call:
/// it reads each drawn row's facts and asks once per change of the rows (``SidebarModel`` caches the answer by
/// content revision), never per frame. A finished answer nobody has read stays where it is with its badge (unread is
/// not settled), Done and archived rows stay in their own folds, a pinned row keeps its place, and no row is made up.
public nonisolated struct SidebarSettlePlanner: Sendable {
    public init() {}

    /// What the rule reads of one row.
    public nonisolated struct Facts: Hashable, Sendable, Encodable {
        /// The row stands for an agent chat (an agent's tab, or one that reported a state).
        public var chat: Bool
        /// The most urgent state of its chats (`settle::Lifecycle`).
        public var lifecycle: Lifecycle
        /// An unread badge, notification or unseen answer.
        public var unread: Bool
        /// It had a turn (any recorded activity); a new, empty chat stays.
        public var hasActivity: Bool
        public var pinned: Bool
        public var archived: Bool
        public var markedDone: Bool

        /// `ws`'s facts; `pinned` when its list is the Pinned section.
        public init(_ ws: SidebarWorkspace, pinned: Bool) {
            chat = ws.kind == .harness || ws.agentChip != nil || ws.agentWorking
            lifecycle = Lifecycle(ws)
            // The Priority chip's Done is "answered and nobody has seen it yet": unread, not settled.
            unread = ws.unread.isUnread || ws.agentChip == .done
            hasActivity = ws.lastActivity != nil
            self.pinned = pinned
            archived = ws.isArchived
            markedDone = ws.taskStatus == .done
        }

        enum CodingKeys: String, CodingKey {
            case chat, lifecycle, unread, pinned, archived
            case hasActivity = "has_activity"
            case markedDone = "marked_done"
        }
    }

    /// `settle::Lifecycle`.
    public nonisolated enum Lifecycle: String, Hashable, Sendable, Encodable {
        case working
        case needsInput = "needs_input"
        case finished, failed, lost
        case ciFailing = "ci_failing"
        case idle

        init(_ ws: SidebarWorkspace) {
            if ws.agentWorking { self = .working; return }
            switch ws.agentChip {
            case .needsYou?: self = .needsInput
            case .done?: self = .finished
            case .failed?: self = .failed
            case .lost?: self = .lost
            case .ciFailing?: self = .ciFailing
            case .working?: self = .working
            case .idle?, nil: self = .idle
            }
        }
    }

    /// What Archive Settled Chats archives, and what it leaves and why (each in the rows' order).
    public nonisolated struct ArchivePlan: Equatable, Sendable {
        /// Settled chats: archiving keeps their history, and their chats reattach.
        public var archive: [WorkspaceID] = []
        /// Answers the person has not read.
        public var unread: [WorkspaceID] = []
        /// Failed turns.
        public var failed: [WorkspaceID] = []
        /// Lost agents.
        public var lost: [WorkspaceID] = []
        /// Working, waiting for an answer, or red CI.
        public var busy: [WorkspaceID] = []

        public init() {}
    }

    /// The settled ones of `rows`. A refused call settles nothing (every row draws in place, as with the setting off).
    public func settled(_ rows: [(id: WorkspaceID, facts: Facts)]) -> Set<WorkspaceID> {
        guard rows.contains(where: { Self.maySettle($0.facts) }) else { return [] }
        guard let reply = call(rows.map(\.facts), trigger: "layout") else { return [] }
        return Set(reply.settled.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    /// Whether `facts` settle.
    public func settles(_ facts: Facts) -> Bool {
        guard Self.maySettle(facts) else { return false }
        return call([facts], trigger: "layout")?.settled == [0]
    }

    /// Archive Settled Chats over `rows`: the settled ones, and the unread, failed, lost and busy ones it leaves.
    public func archivePlan(_ rows: [(id: WorkspaceID, facts: Facts)]) -> ArchivePlan {
        var plan = ArchivePlan()
        guard let reply = call(rows.map(\.facts), trigger: "archive") else { return plan }
        let pick = { (indices: [Int]) in indices.compactMap { rows.indices.contains($0) ? rows[$0].id : nil } }
        plan.archive = pick(reply.settled)
        (plan.unread, plan.failed, plan.lost, plan.busy) = (pick(reply.kept.unread), pick(reply.kept.failed),
                                                            pick(reply.kept.lost), pick(reply.kept.busy))
        return plan
    }

    /// A row the rule cannot settle whatever else holds (not a chat, never ran): no call for a list of terminals.
    static func maySettle(_ facts: Facts) -> Bool { facts.chat && facts.hasActivity }

    // MARK: - Wire (`settle::Request` and `Plan`)

    private struct Request: Encodable {
        var candidates: [Facts]
        var trigger: String
    }

    private struct Reply: Decodable {
        struct Kept: Decodable {
            var unread: [Int] = []
            var failed: [Int] = []
            var lost: [Int] = []
            var busy: [Int] = []
        }
        var settled: [Int]
        var kept: Kept
    }

    private func call(_ candidates: [Facts], trigger: String) -> Reply? {
        RustSidebarClient.call("sidebar_settle_plan", Request(candidates: candidates, trigger: trigger), as: Reply.self)
    }
}
