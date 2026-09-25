import Foundation

/// Split direction used when a terminal link opens a browser surface.
public enum BrowserTerminalLinkSplitDirection: String, CaseIterable, Sendable, SettingCodable {
    /// Place the browser in a right-side pane.
    case right

    /// Place the browser in a pane below the terminal.
    case down
}
