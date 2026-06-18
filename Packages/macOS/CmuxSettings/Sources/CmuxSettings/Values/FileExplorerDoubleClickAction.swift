import Foundation

/// Behavior for activating a file in the right-sidebar file explorer.
///
/// Directory activation is not controlled by this value: directories always
/// expand or collapse in the file tree.
public enum FileExplorerDoubleClickAction: String, CaseIterable, Sendable, SettingCodable {
    /// Open the built-in cmux file preview.
    case preview

    /// Open with the macOS default application for the file type.
    case defaultEditor

    /// Open with `app.preferredEditor`, falling back to the default application.
    case preferredEditor
}
