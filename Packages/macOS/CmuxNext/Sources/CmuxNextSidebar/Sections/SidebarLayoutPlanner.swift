import Foundation

/// Turns user commands ("Add Home to Sidebar", "Pin to Section") into one
/// layout op against the current document. Pure; the caller sends the op.
public nonisolated enum SidebarLayoutPlanner {
    /// Adds `ref` at the start of the first items section of `region`
    /// (creating a section there when none exists). Nil when the layout
    /// already holds `ref` anywhere.
    public static func add(_ ref: LayoutItemRef, to region: SidebarRegion = .top, in document: SidebarLayoutDocument,
                           look: SectionLook = .builtIn, newItem: LayoutItemID = .mint(),
                           newSection: LayoutSectionID = .mint()) -> SidebarLayoutOp? {
        nil
    }

    /// Removes every item with `ref` (the first one; the layout holds at
    /// most one per section, and built-in commands target the first).
    public static func remove(_ ref: LayoutItemRef, in document: SidebarLayoutDocument) -> SidebarLayoutOp? {
        nil
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
        let result = SidebarLayoutReducer.reduce(document, op)
        if case .success(let next) = result { document = next }
        return result
    }
}
