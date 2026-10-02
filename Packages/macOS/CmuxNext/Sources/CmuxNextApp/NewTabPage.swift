import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextTabs
import Foundation

/// What a new tab page does with the user's choice. The page is an agent
/// tab (it shows recent acpmux sessions and becomes a chat in place); a
/// terminal or browser choice replaces it with a tab of that kind.
struct NewTabPageHandler {
    /// `(page tab, kind, text)`: a terminal runs `text`, a browser opens it
    /// as an address or a search.
    var open: (String, AgentPaneTabKind, String) -> Void
    var editShortcut: (AgentPaneTabKind) -> Void
}

enum NewTabPage {
    static let action: ActionID = "newTab.page"

    /// Each kind's New action; the page shows their chords and edits them.
    static let newActions: [AgentPaneTabKind: ActionID] = [
        .terminal: "newSurface", .browser: "openBrowser", .agent: "palette.newAgentChat",
    ]

    /// The page's initially selected kind: the kind of the tab it opens
    /// from, a terminal in an empty pane.
    static func kind(selectedID: String?, selectedKind: TabKind?) -> AgentPaneTabKind {
        if selectedID?.hasPrefix(LocalAgentTab.prefix) == true { return .agent }
        if selectedID?.hasPrefix(LocalBrowserTab.prefix) == true || selectedKind == .browser { return .browser }
        return .terminal
    }

    /// The command line a terminal choice types: nil for an empty field,
    /// else the text run with a newline.
    static func command(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed + "\n"
    }

    /// `~/…` for a folder under `home`, as the page shows it.
    static func displayPath(_ path: String?, home: String = NSHomeDirectory()) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension PaneController {
    /// New Tab Page: an agent tab showing the new tab page, beside the
    /// selected tab, with that tab's kind selected and folder inherited.
    func newTabPage() {
        let selectedID = stripModel.selectedID?.rawValue
        let cwd = selectedTab?.cwd
        let hotkeys = NewTabPage.newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) }
        let page = AgentPaneNewTab(
            kind: NewTabPage.kind(selectedID: selectedID, selectedKind: selectedTab?.kind),
            hotkeys: hotkeys, cwd: NewTabPage.displayPath(cwd)
        )
        let handler = NewTabPageHandler(
            open: { [weak self] key, kind, text in self?.replaceNewTabPage(key, with: kind, text: text, cwd: cwd) },
            editShortcut: { [weak self] kind in self?.editNewTabShortcut(kind) }
        )
        let after = selectedID?.hasPrefix(LocalAgentTab.prefix) == true ? selectedID : nil
        showAgentTab(services.agentTabs.open(in: paneKey, of: daemon.store, after: after, newTab: (page, handler)))
    }

    /// The page chose a terminal or browser: open it, then close the page,
    /// which held nothing yet (the open-beside rule's one replace case).
    private func replaceNewTabPage(_ key: String, with kind: AgentPaneTabKind, text: String, cwd: String?) {
        switch kind {
        case .terminal:
            newTerminalTab(cwd: cwd, typing: NewTabPage.command(text))
        case .browser:
            let url = services.cache.suggestionEngine.resolver.destination(for: text)?.url
            newBrowserTab(url: url)
        case .agent:
            return
        }
        close([StripTabID(key)])
    }

    private func editNewTabShortcut(_ kind: AgentPaneTabKind) {
        guard let id = NewTabPage.newActions[kind] else { return }
        services.palette.show(.keyboardShortcuts)
        services.palette.shortcutRecorder.begin(id)
    }
}
