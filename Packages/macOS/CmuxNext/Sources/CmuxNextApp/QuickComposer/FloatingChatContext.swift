import CmuxNextAgentPane
import CmuxNextBrowser
import Foundation

/// The floating chat's Include focused tab (cx-b9qi): what the user is looking at in cmux, the
/// focused tab of the active main window (the floating panel never becomes one). A terminal gives
/// its selection, else the text it shows; a page its title, URL and selection, as New Agent Chat
/// seeds from a tab (``AgentTabSeed``). Nil from an agent tab, an empty pane or no window.
enum FloatingChatContext {
    @MainActor static func focused(in services: AppServices?) async -> AgentPaneQuickContext? {
        guard let pane = services?.windows.active?.focusedPane else { return nil }
        let title = trimmed(pane.stripModel.selectedID.flatMap { pane.stripModel.tab($0)?.title }) ?? untitled
        switch pane.currentContent {
        case .terminal(let entry):
            let view = entry.session.surfaceView
            if let selection = trimmed(view.accessibilitySelectedText()) {
                return AgentPaneQuickContext(name: selectionName(title), text: selection)
            }
            // Read once, on request: it takes the surface's lock.
            return trimmed(view.viewportText()).map { AgentPaneQuickContext(name: title, text: $0) }
        case .browser(let entry):
            let page = entry.tab
            let selection = try? await page.evaluate(AgentTabSeed.selectionScript, world: .isolated, gesture: .cmux).stringValue
            guard let text = AgentTabSeed.browserDraft(title: page.state.title, url: page.state.url, selection: selection) else { return nil }
            let name = trimmed(page.state.title) ?? title
            return AgentPaneQuickContext(name: trimmed(selection) == nil ? name : selectionName(name),
                                         text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .agent, .page, .placeholder, .notice, .conversation, nil:
            return nil
        }
    }

    /// An untitled tab's chip name.
    private static var untitled: String {
        String(localized: "floatingChat.context.untitled", defaultValue: "Focused tab", table: "FloatingChat", bundle: .module)
    }

    private static func selectionName(_ title: String) -> String {
        String(localized: "floatingChat.context.selection", defaultValue: "\(title) (selection)", table: "FloatingChat", bundle: .module)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > AgentTabSeed.selectionLimit ? String(text.prefix(AgentTabSeed.selectionLimit)) + "…" : text
    }
}
