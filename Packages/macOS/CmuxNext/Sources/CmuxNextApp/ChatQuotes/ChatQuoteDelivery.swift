import AppKit
import CmuxNextAgentPane
import CmuxNextDaemonService
import CmuxNextHome
import CmuxNextPages

/// Puts a viewer quote in its chat's composer as a card (viewer-comments-DESIGN.md), through the
/// design mode highlight's own paths, so both make the same card: the agent chat that opened the
/// file gets ``AgentPaneDesignSelection`` chips. Nothing is sent.
@MainActor
struct ChatQuoteDelivery {
    let services: AppServices

    func deliver(_ quote: ChatQuote, from window: NSWindow?) {
        let tabs = services.agentTabs
        let target = services.chatQuoteOpeners.target(for: quote.source) { tabs.views[tabs.resolve($0)]?.model.hasHandshake == true }
        if case .agentTab(let key) = target, let view = tabs.views[tabs.resolve(key)] {
            AgentPaneDesignSelection(id: "quote-" + UUID().uuidString, name: quote.title, text: quote.markdown, png: nil).push(to: view)
            return
        }
        // Home's chat is the web Messages page, whose composer takes no native files yet
        // (home-react follow-up: a page op for quotes and cards).
        services.registry.refuse(RefusalStrings.homeQuoteNoHome)
    }
}
