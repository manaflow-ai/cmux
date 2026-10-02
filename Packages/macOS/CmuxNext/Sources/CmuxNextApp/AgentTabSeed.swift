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
    /// and selection, a page's title, URL and selection (with the pane's
    /// terminal cwd). Nil from an agent tab or an empty pane.
    func agentSeedFromSelectedTab() -> AgentPaneSeedSource? {
        switch currentContent {
        case .terminal(let entry):
            let selection = entry.session.surfaceView.accessibilitySelectedText()
            return AgentPaneSeedSource(AgentPaneSeed(cwd: selectedTab?.cwd, draft: AgentTabSeed.terminalDraft(selection: selection)))
        case .browser(let entry):
            let page = entry.tab
            let title = page.state.title
            let url = page.state.url
            // A page has no cwd: the pane's last terminal tab's, in strip order.
            let cwd = pane.tabs.last { $0.kind == .pty && $0.cwd != nil }?.cwd
            return AgentPaneSeedSource { [weak page] in
                let selection = try? await page?.evaluate(AgentTabSeed.selectionScript, world: .isolated).stringValue
                return AgentPaneSeed(cwd: cwd, draft: AgentTabSeed.browserDraft(title: title, url: url, selection: selection))
            }
        case .agent, .placeholder, .conversation, nil:
            return nil
        }
    }
}
