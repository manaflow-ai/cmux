import Foundation

/// Where the cmux browser opens a clicked terminal link or an intercepted `open` URL.
public enum TerminalLinkBrowserPlacement: String, CaseIterable, Sendable, SettingCodable {
    /// Reuse the pane to the right of the terminal, or split one off when none exists.
    case split
    /// Add a browser tab to the pane that holds the terminal.
    case samePane
}
