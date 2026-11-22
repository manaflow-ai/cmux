import Foundation

// S1 (DOGFOOD-CALL-2026-10-06, coordinator): the New Workspace and Import
// and Sync sidebar items are retired. Their actions stay in the palette and
// the menus. A stored layout that still holds one (the #17349 tiles, or an
// item the user added) drops it through ordinary item removals, silently.
extension SidebarLayoutDocument {
    /// Raw values of built-ins that are no longer sidebar items.
    public nonisolated static let retiredBuiltIns: Set<String> = ["new_workspace", "import_sync"]

    /// One removal per item, in any section, whose ref is a retired built-in.
    public nonisolated var retiredItemOps: [SidebarLayoutOp] {
        sections.flatMap(\.items)
            .filter { $0.ref.kind == LayoutItemRef.builtInKind && Self.retiredBuiltIns.contains($0.ref.value) }
            .map { .itemRemove($0.id) }
    }
}
