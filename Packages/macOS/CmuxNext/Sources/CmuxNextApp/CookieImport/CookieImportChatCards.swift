import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextCookieImport

/// An agent's cookie import ask inline in its own chat tab: the permission card as a tool card
/// (``AgentPaneToolCard``, text and buttons) above that chat's composer, following the ask through
/// its phases until the person closes it. A click there is the person's only with a real gesture
/// in the pane (``AgentPaneToolCard/respond``), so page script cannot answer for them.
@MainActor
struct CookieImportChatCards {
    /// The card's owner in ``AgentToolCards``.
    static let owner = "cookieImport"

    let services: AppServices

    /// Shows `ask` in chat tab `tab` when that chat is on screen now; false otherwise.
    func show(_ ask: CookieImportAsk, tab: String) -> Bool {
        guard let view = services.agentTabs.existingView(tab), Self.isOnScreen(view) else { return false }
        let cards = services.cloud.toolCards
        let answer: AgentToolCards.Answer = { [weak ask] _, action, _ in ask?.perform(action) }
        guard cards.set([Self.card(ask)], owner: Self.owner, tab: tab, answer: answer) else { return false }
        // task-owner: lives until the ask is dismissed; event-driven (Observation)
        Task { @MainActor [weak cards] in
            for await card in ObservationStream({ ask.isDismissed ? nil : ask.textCard }) {
                guard card != nil else { break }
                cards?.set([Self.card(ask)], owner: Self.owner, tab: tab, answer: answer)
            }
            cards?.set([], owner: Self.owner, tab: tab) { _, _, _ in }
        }
        return true
    }

    static func card(_ ask: CookieImportAsk) -> AgentPaneToolCard {
        let shown = ask.textCard
        let state: AgentPaneToolCard.State = switch ask.phase {
        case .asking, .imported, .removed: .ask
        case .reading: .working
        case .ended: .failed
        }
        return AgentPaneToolCard(id: ask.id, state: state, text: shown.text,
                                 actions: shown.actions.map { AgentPaneToolCard.Action(id: $0.id, title: $0.title) })
    }

    /// In a visible, unoccluded window and not hidden.
    static func isOnScreen(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }
}
