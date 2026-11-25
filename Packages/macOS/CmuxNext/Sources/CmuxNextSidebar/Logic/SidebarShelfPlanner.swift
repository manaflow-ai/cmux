public import Foundation

/// The working shelf (`sidebar.workingShelf`, off by default; Leo's feature map 2026-11-23, item 16: "Chats waiting
/// on subagents, checks or watches fold into one row and return when they need you"). An agent chat whose turn ended
/// and that waits on work that wakes it by itself (a background task that notifies, a watch, a background subagent, a
/// working sub-session: acpmux's summary `backgroundWaits`) leaves its list's working order for a "Working (N)" row
/// (`SidebarLayout.foldingDone`); the wait's end starts a turn, and a question, an unread answer, a failure or a lost
/// agent brings it back too, since the rule reads the row's live state each time.
///
/// The rule is Rust's (`cmux-layout-reducer` `shelf`, op `sidebar_shelf_plan`); this is the app's side of the call,
/// asked once per change of the rows (``SidebarModel`` caches the answer by content revision), never per frame.
public nonisolated struct SidebarShelfPlanner: Sendable {
    public init() {}

    /// What the rule reads of one row (`shelf::Candidate`).
    public nonisolated struct Facts: Hashable, Sendable, Encodable {
        public var chat: Bool
        public var lifecycle: SidebarSettlePlanner.Lifecycle
        public var unread: Bool
        /// What its chats wait on that wakes them by themselves, summed.
        public var backgroundWaits: Int
        public var pinned: Bool
        public var archived: Bool
        public var markedDone: Bool

        /// `ws`'s facts; `pinned` when its list is the Pinned section.
        public init(_ ws: SidebarWorkspace, pinned: Bool) {
            let settle = SidebarSettlePlanner.Facts(ws, pinned: pinned)
            chat = settle.chat
            lifecycle = settle.lifecycle
            unread = settle.unread
            backgroundWaits = max(0, ws.backgroundWaits)
            self.pinned = pinned
            archived = settle.archived
            markedDone = settle.markedDone
        }

        enum CodingKeys: String, CodingKey {
            case chat, lifecycle, unread, pinned, archived
            case backgroundWaits = "background_waits"
            case markedDone = "marked_done"
        }
    }

    /// The shelved ones of `rows`. A refused call shelves nothing (every row draws in place, as with the setting off).
    public func shelved(_ rows: [(id: WorkspaceID, facts: Facts)]) -> Set<WorkspaceID> {
        guard rows.contains(where: { Self.mayShelve($0.facts) }) else { return [] }
        guard let reply = call(rows.map(\.facts)) else { return [] }
        return Set(reply.shelved.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    /// Whether `facts` shelve.
    public func shelves(_ facts: Facts) -> Bool {
        guard Self.mayShelve(facts) else { return false }
        return call([facts])?.shelved == [0]
    }

    /// A row the rule cannot shelve whatever else holds (not a chat, waits on nothing): no call for a quiet list.
    static func mayShelve(_ facts: Facts) -> Bool { facts.chat && facts.backgroundWaits > 0 }

    // MARK: - Wire (`shelf::Request` and `Plan`)

    private struct Request: Encodable { var candidates: [Facts] }
    private struct Reply: Decodable { var shelved: [Int] }

    private func call(_ candidates: [Facts]) -> Reply? {
        RustSidebarClient.call("sidebar_shelf_plan", Request(candidates: candidates), as: Reply.self)
    }
}
