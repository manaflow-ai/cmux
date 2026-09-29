import Foundation

/// Labels and factory defaults for the diff viewer's file and hunk jumps.
/// Split out of `KeyboardShortcutSettings.swift` the same way the Simulator
/// actions are, so adding a navigation action does not grow that file.
extension KeyboardShortcutSettings.Action {
    var diffViewerNavigationLabel: String {
        switch self {
        case .diffViewerNextFile:
            String(localized: "shortcut.diffViewerNextFile.label", defaultValue: "Diff Viewer: Next File")
        case .diffViewerPreviousFile:
            String(localized: "shortcut.diffViewerPreviousFile.label", defaultValue: "Diff Viewer: Previous File")
        case .diffViewerNextHunk:
            String(localized: "shortcut.diffViewerNextHunk.label", defaultValue: "Diff Viewer: Next Hunk")
        case .diffViewerPreviousHunk:
            String(localized: "shortcut.diffViewerPreviousHunk.label", defaultValue: "Diff Viewer: Previous Hunk")
        default:
            preconditionFailure("Not a diff viewer navigation shortcut action")
        }
    }

    /// `] f` / `[ f` chords jump between files; bare `n` / `p` jump between
    /// hunks, following the viewer's vim-style `j` / `k` scrolling.
    var diffViewerNavigationDefaultShortcut: StoredShortcut {
        switch self {
        case .diffViewerNextFile:
            StoredShortcut(
                first: ShortcutStroke(key: "]", command: false, shift: false, option: false, control: false),
                second: ShortcutStroke(key: "f", command: false, shift: false, option: false, control: false)
            )
        case .diffViewerPreviousFile:
            StoredShortcut(
                first: ShortcutStroke(key: "[", command: false, shift: false, option: false, control: false),
                second: ShortcutStroke(key: "f", command: false, shift: false, option: false, control: false)
            )
        case .diffViewerNextHunk:
            StoredShortcut(key: "n", command: false, shift: false, option: false, control: false)
        case .diffViewerPreviousHunk:
            StoredShortcut(key: "p", command: false, shift: false, option: false, control: false)
        default:
            preconditionFailure("Not a diff viewer navigation shortcut action")
        }
    }
}
