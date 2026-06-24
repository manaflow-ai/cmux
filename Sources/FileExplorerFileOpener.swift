import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Performs the user-configured double-click action for a FILE in the file
/// explorer.
///
/// Owns the responsibility that was previously a free function: read the
/// `FileExplorerDoubleClickActionSettings` choice, resolve it against whether a
/// preferred-editor command is configured, and dispatch to the cmux preview, the
/// macOS default application (``CmuxPanes/FileExternalOpener``), or the
/// configured preferred editor (``CmuxWorkspaces/PreferredEditorService``).
///
/// Shared by every file-activation gesture (the outline view's double-click and
/// the search results list's double-click / Return) so the behavior stays
/// consistent across surfaces. Callers must guard for local providers and skip
/// directories before invoking ``open(path:onOpenFilePreview:)`` — only readable
/// local files reach here.
@MainActor
struct FileExplorerFileOpener {
    /// Defaults backing both the resolved double-click action and the
    /// preferred-editor command lookup.
    private let defaults: UserDefaults
    /// Opener used for the macOS default-application activation.
    private let externalOpener: FileExternalOpener

    init(defaults: UserDefaults = .standard, externalOpener: FileExternalOpener = .live) {
        self.defaults = defaults
        self.externalOpener = externalOpener
    }

    /// Open `path` according to the configured file-activation behavior.
    ///
    /// `onOpenFilePreview` opens the built-in cmux preview and stays app-side; it
    /// is invoked for the `.preview` activation.
    func open(path: String, onOpenFilePreview: (String) -> Void) {
        let action = FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults)
        let hasPreferredEditor = PreferredEditorSettingsStore(defaults: defaults).resolvedCommand != nil
        switch FileExplorerDoubleClickActionSettings.fileActivation(
            action: action,
            hasPreferredEditorCommand: hasPreferredEditor
        ) {
        case .preview:
            onOpenFilePreview(path)
        case .defaultEditor:
            _ = externalOpener.openDefault(fileURL: URL(fileURLWithPath: path))
        case .preferredEditor:
            PreferredEditorService(defaults: defaults).open(URL(fileURLWithPath: path))
        }
    }
}
