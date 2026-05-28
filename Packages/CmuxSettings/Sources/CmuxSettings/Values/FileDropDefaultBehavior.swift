import Foundation

/// What cmux does when a file is dragged onto a terminal pane.
public enum FileDropDefaultBehavior: String, CaseIterable, Sendable, SettingCodable {
    /// Insert the file path as terminal text. Shift inverts on drop.
    case path
    /// Open the file in the preferred editor.
    case editor
    /// Split-and-open in cmux's preview viewer.
    case preview
}
