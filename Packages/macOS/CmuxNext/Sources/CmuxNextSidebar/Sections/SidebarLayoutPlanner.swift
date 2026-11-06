import Foundation

/// Turns user commands ("Add Home to Sidebar", "Pin to Section") into one
/// layout op against the current document (Rust `sidebar_layout_plan::add_op`
/// and `remove_op`). Pure; the caller sends the op.
public nonisolated enum SidebarLayoutPlanner {
    /// Adds `ref` to the first items section of `region` that shows in
    /// every room: first in the top region, last elsewhere. With no such
    /// section, adds one (no title, `look`) holding the item. Nil when the
    /// layout already holds `ref` anywhere.
    public static func add(_ ref: LayoutItemRef, to region: SidebarRegion = .top, in document: SidebarLayoutDocument,
                           look: SectionLook = .builtIn, showsLabel: Bool = true, newItem: LayoutItemID = .mint(),
                           newSection: LayoutSectionID = .mint()) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("add", document: document)
        request.ref = ref
        request.region = region
        request.look = look
        request.showsLabel = showsLabel
        request.newItem = newItem
        request.newSection = newSection
        return SidebarLayoutReducer.plan(request)?.op
    }

    /// Removes every item with `ref` ("Remove Home from Sidebar"); nil
    /// when the layout holds none.
    public static func remove(_ ref: LayoutItemRef, in document: SidebarLayoutDocument) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("remove", document: document)
        request.ref = ref
        return SidebarLayoutReducer.plan(request)?.op
    }
}

/// An owner of the layout that keeps the document in memory: the DEV
/// prototype owner (`sidebar.sections.localPrototype`) and the reference
/// model in tests. It applies each op once per idempotency key, like the
/// store's ledger (invariant 5).
public nonisolated struct SidebarLayoutMemoryOwner: Sendable {
    public private(set) var document: SidebarLayoutDocument
    private var ledger: [String: (op: SidebarLayoutOp, result: Result<SidebarLayoutDocument, SidebarLayoutReject>)] = [:]

    public init(document: SidebarLayoutDocument = .defaults) {
        self.document = document
    }

    /// Applies `op` under `key`. Replaying the same key and op returns the
    /// stored result and changes nothing; the same key with another op is
    /// refused.
    public mutating func apply(_ op: SidebarLayoutOp, key: String) -> Result<SidebarLayoutDocument, SidebarLayoutReject> {
        if let entry = ledger[key] {
            return entry.op == op ? entry.result : .failure(.idempotencyConflict)
        }
        let result = SidebarLayoutReducer.reduce(document, op)
        if case .success(let next) = result { document = next }
        ledger[key] = (op, result)
        return result
    }
}
