import Foundation

/// The name a workspace made from dragged or moved tabs takes (Lawrence,
/// 2026-10-02: "workspace name should be adopted from the name of the tab
/// that was dragged out"). Pure, so every case is tested; the one shared
/// path `TabMoves.toNewWorkspace` (drag, tear-off, palette, CLI, Move Pane)
/// and `TabGroupMoves.toNewWorkspace` apply it.
nonisolated enum NewWorkspaceName {
    /// What the rule reads from one tab.
    struct Tab: Equatable {
        enum Kind: Equatable { case terminal, browser, remoteTerminal }
        var kind: Kind
        /// The name the user gave the tab.
        var userName: String?
        /// The terminal's live title (OSC 0/2), or the browser record's title.
        var title: String?
        /// A browser's live page title (the page the app renders).
        var pageTitle: String?
        var url: String?
        var cwd: String?
    }

    static let maxLength = 80

    /// The name for a workspace made from `tab`, or nil to keep the
    /// daemon's default. Order: the tab's user name, then a browser's page
    /// title (else its host), or a terminal's live title (a bare shell name
    /// such as "zsh" reads as the directory instead), then the directory.
    static func forTab(_ tab: Tab) -> String? {
        nil
    }

    /// The name for a workspace made from a tab group: its name, else its
    /// first tab's.
    static func forGroup(name: String?, firstTab: Tab?) -> String? {
        nil
    }
}
