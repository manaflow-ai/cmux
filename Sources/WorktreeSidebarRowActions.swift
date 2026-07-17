/// Closure bundle passed below the lazy-list snapshot boundary.
struct WorktreeSidebarRowActions {
    let openTerminal: @MainActor (WorktreeSidebarRow) -> Void
    let delete: @MainActor (WorktreeSidebarRow) -> Void
    let becameVisible: @MainActor (WorktreeSidebarRow) -> Void
    let becameHidden: @MainActor (WorktreeSidebarRow) -> Void

    @MainActor
    static func bound(to model: WorktreeSidebarModel) -> WorktreeSidebarRowActions {
        WorktreeSidebarRowActions(
            openTerminal: { model.openTerminal(for: $0) },
            delete: { model.requestDeletion(for: $0) },
            becameVisible: { model.rowBecameVisible($0) },
            becameHidden: { model.rowBecameHidden($0) }
        )
    }
}
