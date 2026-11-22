public import Foundation

/// Automatic sessions (`sidebar.showAutomaticSessions`, off by default): a workspace no person started and that is no
/// chat's subagent (a script, an automation, a launcher or a daemon made it; its daemon recorded `created_by` kind
/// `script` at the create) leaves its list's working order for one "Automatic (N)" row at the list's end
/// (`SidebarLayout.foldingDone`); the row opens them below it. A person's rows and subagents always show, and so does an
/// automatic row that is pinned or needs the person.
///
/// The rule is Rust's (`cmux-layout-reducer` `automatic`, op `sidebar_automatic_plan`); this is the app's side of the
/// call: it reads each drawn row's facts and asks once per change of the rows (``SidebarModel`` caches the answer by
/// content revision), never per frame.
public nonisolated struct SidebarAutomaticPlanner: Sendable {
    public init() {}

    /// What the rule reads of one row.
    public nonisolated struct Facts: Hashable, Sendable, Encodable {
        public var createdBy: SidebarCreator?
        public var pinned: Bool
        /// A question or a permission prompt waits for the person.
        public var needsInput: Bool
        public var archived: Bool
        public var markedDone: Bool

        /// `ws`'s facts; `pinned` when its list is the Pinned section.
        public init(_ ws: SidebarWorkspace, pinned: Bool) {
            createdBy = ws.createdBy
            self.pinned = pinned
            needsInput = ws.agentChip == .needsYou
            archived = ws.isArchived
            markedDone = ws.taskStatus == .done
        }

        enum CodingKeys: String, CodingKey {
            case pinned, archived
            case createdBy = "created_by"
            case needsInput = "needs_input"
            case markedDone = "marked_done"
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(createdBy?.rawValue, forKey: .createdBy)
            try c.encode(pinned, forKey: .pinned)
            try c.encode(needsInput, forKey: .needsInput)
            try c.encode(archived, forKey: .archived)
            try c.encode(markedDone, forKey: .markedDone)
        }
    }

    /// The automatic ones of `rows`; none with `showAutomatic` (`sidebar.showAutomaticSessions` on). A refused call
    /// folds nothing (every row draws in place, as with the setting on).
    public func automatic(_ rows: [(id: WorkspaceID, facts: Facts)], showAutomatic: Bool) -> Set<WorkspaceID> {
        guard !showAutomatic, rows.contains(where: { Self.mayFold($0.facts) }) else { return [] }
        let request = Request(candidates: rows.map(\.facts), showAutomatic: false)
        guard let reply = RustSidebarClient.call("sidebar_automatic_plan", request, as: Reply.self) else { return [] }
        return Set(reply.automatic.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    /// A row the rule cannot fold whatever else holds (the person or an agent made it): no call for a list of those.
    static func mayFold(_ facts: Facts) -> Bool { facts.createdBy == .script }

    // MARK: - Wire (`automatic::Request` and `Plan`)

    private struct Request: Encodable {
        var candidates: [Facts]
        var showAutomatic: Bool

        enum CodingKeys: String, CodingKey {
            case candidates
            case showAutomatic = "show_automatic"
        }
    }

    private struct Reply: Decodable {
        var automatic: [Int]
    }
}
