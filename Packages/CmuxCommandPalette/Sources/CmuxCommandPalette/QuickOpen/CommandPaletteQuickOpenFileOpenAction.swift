public import Foundation

/// The safe open behavior Quick Open should use for a selected file.
public enum CommandPaletteQuickOpenFileOpenAction: Sendable {
    /// Open the file through Launch Services.
    case open(URL)
    /// Reveal the file in Finder rather than executing it.
    case reveal(URL)
    /// Open the file explicitly as plain text.
    case textEditor(URL)
}
