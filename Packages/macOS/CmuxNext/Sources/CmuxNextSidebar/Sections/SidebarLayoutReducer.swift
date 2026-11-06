import Foundation

/// The section layout reducer: `(document, op) -> document or reject`,
/// checking invariants L1-L6 (plans/cmux-next/sidebar-sections.md 4). It is
/// the store's own reducer (Rust `cmux_layout_reducer::sidebar_layout`, op
/// `sidebar_layout_reduce` of the layout reducer FFI), so the edit a client
/// overlays on its confirmed mirror is the one the store will commit
/// (cx-qvj1: the Swift copy had drifted).
public nonisolated enum SidebarLayoutReducer {
    /// The new document, or the reject. A change bumps `revision` by one;
    /// a no-op returns the document unchanged. When the FFI cannot answer
    /// (it never should), the document comes back unchanged: the store
    /// still checks the op.
    public static func reduce(_ document: SidebarLayoutDocument, _ op: SidebarLayoutOp) -> Result<SidebarLayoutDocument, SidebarLayoutReject> {
        // The document as the app encodes it (`revision` a number), never the
        // daemon's `sidebar_layout.get` JSON, whose `revision` is a string.
        let reply = RustSidebarClient.call("sidebar_layout_reduce", RustLayoutRequest(document: document, op: op), as: RustLayoutReply.self)
        if let next = reply?.document { return .success(next) }
        if let reason = reply?.reject, let reject = SidebarLayoutReject(rawValue: reason) { return .failure(reject) }
        return .success(document)
    }

    /// The layout planners (Rust `cmux_layout_reducer::sidebar_layout_plan`,
    /// op `sidebar_layout_plan`): pins, Add to Top, undo, Add to Sidebar,
    /// hidden-row indexes, region reorder and the one-time migrations, each
    /// answered as ordinary layout ops. Nil when the FFI cannot answer.
    static func plan(_ request: SidebarLayoutPlanRequest) -> SidebarLayoutPlanReply? {
        RustSidebarClient.call("sidebar_layout_plan", request, as: SidebarLayoutPlanReply.self)
    }

    static func locate(_ id: LayoutItemID, in sections: [LayoutSection]) -> (Int, Int)? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.id == id }) { return (s, i) }
        }
        return nil
    }
}

private nonisolated struct RustLayoutRequest: Encodable {
    let document: SidebarLayoutDocument
    let op: SidebarLayoutOp
}

/// `{"document": ...}` or `{"reject": "<reason>"}`.
private nonisolated struct RustLayoutReply: Decodable {
    let document: SidebarLayoutDocument?
    let reject: String?
}

/// One planner request, tagged by `plan`; each plan reads only its own keys.
nonisolated struct SidebarLayoutPlanRequest: Encodable {
    /// One ref of a multi-pin, with the item id its pin mints.
    struct Pin: Encodable {
        var ref: LayoutItemRef
        var label: String?
        var newItem: LayoutItemID

        enum CodingKeys: String, CodingKey {
            case ref, label
            case newItem = "new_item"
        }
    }

    var plan: String
    var document: SidebarLayoutDocument?
    var ref: LayoutItemRef?
    var label: String?
    var newItem: LayoutItemID?
    var newSection: LayoutSectionID?
    var pins: [Pin]?
    var pinned: Bool?
    var op: SidebarLayoutOp?
    var region: SidebarRegion?
    var look: SectionLook?
    var showsLabel: Bool?
    var stored: SidebarLayoutDocument?
    var projected: SidebarLayoutDocument?
    var section: LayoutSectionID?
    var index: Int?
    var excluding: LayoutItemID?
    var subject: [String: String]?
    var shown: [LayoutSection]?
    var id: LayoutSectionID?
    var before: LayoutSectionID?

    init(_ plan: String, document: SidebarLayoutDocument? = nil) {
        self.plan = plan
        self.document = document
    }

    enum CodingKeys: String, CodingKey {
        case plan, document, ref, label, pins, pinned, op, region, look, stored, projected, section, index, excluding, subject, shown, id,
             before
        case newItem = "new_item"
        case newSection = "new_section"
        case showsLabel = "shows_label"
    }
}

/// `{"op": ...}` (absent: nothing to do), `{"ops": [...]}` or `{"index": n}`.
nonisolated struct SidebarLayoutPlanReply: Decodable {
    var op: SidebarLayoutOp?
    var ops: [SidebarLayoutOp]?
    var index: Int?
}
