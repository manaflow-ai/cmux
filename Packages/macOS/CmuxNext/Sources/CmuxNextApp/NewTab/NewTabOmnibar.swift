import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser

/// The New Tab page's omnibar (cx-e2aa, Lawrence 2026-10-09: "we should show the omnibar in new
/// tab page. so people can just cmd+l to explicitly do new tab"). The browser's own omnibar row
/// (`OmnibarToolbarView`, the same `AddressBarView` and suggestions a browser tab has) sits on top
/// of the page while the pane is a New Tab page; Cmd-L there gives it the keyboard. An address it
/// commits replaces the page with a browser tab through the page's own `tab.open` path.
enum NewTabOmnibar {
    /// What an omnibar boundary does on the page.
    enum Outcome: Equatable {
        /// Editing began: the page counts as touched (a recycled spare must not keep the text).
        case touch
        /// The page becomes this tab (the page's `tab.open`).
        case open(AgentPaneOpenTab)
        /// A Switch to Tab row: reveal that tab.
        case reveal(String)
        /// Escape: the keyboard goes back to the page's field.
        case returnToPage
        case none
    }

    static let identifier = "newTab.omnibar"

    static func outcome(for event: OmnibarEvent) -> Outcome {
        switch event {
        case .didBeginEditing: .touch
        // A modified commit (Cmd-Enter) has no current page to keep: the page opens it too.
        case .didEndEditing(.commit(let url)), .didEndEditing(.open(let url, _)):
            .open(AgentPaneOpenTab(kind: .browser, text: url.absoluteString))
        case .didEndEditing(.switchToTab(let key)): .reveal(key)
        case .didEndEditing(.cancel): .returnToPage
        // No extension keywords on the page (they belong to a Chromium tab), and a blur is the
        // focus owner's.
        case .didEndEditing(.blur), .didEndEditing(.keyword): .none
        }
    }

    /// Gives `view` its omnibar row; the pane shows it while it is a New Tab page.
    @MainActor static func install(on view: AgentPaneView, services: AppServices) {
        let row = OmnibarToolbarView(suggestionEngine: services.cache.suggestionEngine)
        row.addressBar.setAccessibilityIdentifier(identifier)
        row.cardClip = view
        row.addressBar.onEvent = { [weak services, weak view] event in
            guard let services, let view else { return }
            switch outcome(for: event) {
            case .open(let request):
                // The tab the view shows (a spare shows none).
                guard let key = services.agentTabs.views.first(where: { $0.value === view })?.key,
                      let page = services.agentTabs.newTabPage(key) else { return }
                page.handler.open(key, request)
            case .reveal(let tab):
                _ = services.revealTab(tab)
            case .touch:
                Task { _ = await view.model.respond(to: .touched) }
            case .returnToPage:
                view.window?.makeFirstResponder(view.webView)
            case .none:
                break
            }
        }
        view.setTopAccessory(row, height: row.preferredHeight)
    }

    /// Cmd-L on a New Tab page: its omnibar takes the keyboard. False when the page shows none.
    @MainActor static func focus(in view: AgentPaneView) -> Bool {
        guard let row = view.topAccessory as? OmnibarToolbarView, !row.isHidden else { return false }
        row.addressBar.focus()
        return true
    }
}
