import AppKit
import CmuxSettings
import CmuxWorkspaces

/// Performs the configured double-click action for a FILE in the file explorer.
///
/// Shared by every file-activation gesture (the outline view's double-click and
/// the search results list's double-click / Return) so the behavior stays
/// consistent across surfaces. Callers must guard for local providers and skip
/// directories before calling this — only readable local files reach here.
///
/// The injected `defaults` backs both the preferred-editor command lookup and
/// the preferred-editor open, so tests can drive the activation branches with a
/// scoped `UserDefaults`.
struct FileExplorerFileOpener {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @MainActor
    func open(path: String, onOpenFilePreview: (String) -> Void) {
        let action = FileExplorerDoubleClickActionSettings.resolvedAction()
        let hasPreferredEditor = PreferredEditorSettingsStore(defaults: defaults).resolvedCommand != nil
        switch FileExplorerDoubleClickActionSettings.fileActivation(
            action: action,
            hasPreferredEditorCommand: hasPreferredEditor
        ) {
        case .preview:
            onOpenFilePreview(path)
        case .defaultEditor:
            FileExternalOpenAction.openDefault(fileURL: URL(fileURLWithPath: path))
        case .preferredEditor:
            PreferredEditorService(defaults: defaults).open(URL(fileURLWithPath: path))
        }
    }
}
