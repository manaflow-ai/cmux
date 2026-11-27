import CmuxNextDaemon

/// What a Todo page row may do, as closures: rows hold no model (the snapshot-boundary rule).
struct WorkspaceTodoRowActions {
    var toggle: @MainActor (String) -> Void
    var setState: @MainActor (String, WorkspaceChecklistItem.State) -> Void
    var beginEdit: @MainActor (String) -> Void
    var commitEdit: @MainActor (String, String) -> Void
    var cancelEdit: @MainActor () -> Void
    var attachImages: @MainActor (String) -> Void
    var remove: @MainActor (String) -> Void
}
