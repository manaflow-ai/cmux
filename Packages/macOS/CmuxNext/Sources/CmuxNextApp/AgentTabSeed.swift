import CmuxNextAgentPane
import CmuxNextBrowser
import Foundation

/// What New Agent Chat takes from the tab it was opened from (#16620): a
/// terminal's cwd and selection, a page's title, URL and selection. The
/// draft has no prose of its own, so it reads the same in every language.
enum AgentTabSeed {
    /// The longest selection the draft carries, in characters.
    static let selectionLimit = 8_000

    /// The page's selection, read in an isolated world (the DOM selection is
    /// shared, page globals are not).
    static let selectionScript = "String(window.getSelection ? window.getSelection() : '')"

    /// A terminal's selection as a fenced block, or nil without one.
    static func terminalDraft(selection: String?) -> String? {
        guard let text = trimmed(selection) else { return nil }
        // A fence longer than any backtick run inside keeps the block whole.
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\n\(text)\n\(fence)\n\n"
    }

    /// A page's title and URL, then its selection quoted, or nil for a page
    /// with neither (a blank tab).
    static func browserDraft(title: String?, url: URL?, selection: String?) -> String? {
        var lines: [String] = []
        let address = url.flatMap { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil }
        if let title = trimmed(title), title != address { lines.append(title) }
        if let address { lines.append(address) }
        if let text = trimmed(selection) {
            if !lines.isEmpty { lines.append("") }
            lines += text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> \($0)" }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n\n"
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > selectionLimit ? String(text.prefix(selectionLimit)) + "…" : text
    }
}

extension PaneController {
    /// The seed for a chat opened from the selected tab: a terminal's cwd
    /// and selection, a page's title, URL and selection. Its folder and harness are the ones the
    /// person works in (NEW-WORK-INHERITS-CONTEXT, ``WorkContextTrail``): the folder of the
    /// selected terminal or chat, else of the terminal or chat focused last in this workspace
    /// (then in the window, for a workspace with none); the harness of the chat focused last.
    /// Nil when there is nothing to inherit.
    func agentSeedFromSelectedTab() -> AgentPaneSeedSource? {
        let cwd = NewTerminalStart.inherited(besides: selectedTab, in: pane, services: services)
        let harness = inheritedHarness()
        switch currentContent {
        case .terminal(let entry):
            let selection = entry.session.surfaceView.accessibilitySelectedText()
            return AgentPaneSeedSource(AgentPaneSeed(cwd: cwd ?? selectedTab?.cwd, draft: AgentTabSeed.terminalDraft(selection: selection),
                                                     harness: harness))
        case .browser(let entry):
            let page = entry.tab
            let title = page.state.title
            let url = page.state.url
            // A page has no cwd: the folder of the terminal or chat focused last, else the pane's
            // last terminal tab's, in strip order.
            let pageCwd = cwd ?? pane.tabs.last { $0.kind == .pty && $0.cwd != nil }?.cwd
            return AgentPaneSeedSource { [weak page] in
                let selection = try? await page?.evaluate(AgentTabSeed.selectionScript, world: .isolated, gesture: .cmux).stringValue
                return AgentPaneSeed(cwd: pageCwd, draft: AgentTabSeed.browserDraft(title: title, url: url, selection: selection), harness: harness)
            }
        case .agent, .page, .placeholder, .notice, .conversation, nil:
            guard cwd != nil || harness != nil else { return nil }
            return AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, harness: harness))
        }
    }

    /// The harness of the agent chat the person focused last (the selected chat first), by the
    /// rule of ``WorkContextTrail``; nil when no chat of this Mac is a source.
    func inheritedHarness() -> String? {
        let tabs = services.agentTabs
        return services.inheritedWork(besides: selectedTab, in: pane, kinds: [.chat]) { tab in
            guard tabs.lookup(tab.id)?.record.host == tabs.localHost else { return nil }
            return tabs.harness(ofTab: tab.id)
        }
    }
}
