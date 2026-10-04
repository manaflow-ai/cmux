import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The R114 card stack: the update card (the updater's gate decides
/// whether one shows) and, later, what's new and announcements.
extension SidebarBridge {
    static let updateCardID = "update"

    func observeCards() {
        let updater = services.updater
        let model = model
        model.onCardAction = { [weak updater] id, action in
            guard id == Self.updateCardID, let updater else { return }
            switch action {
            case .open: updater.cardClicked()
            case .button(UpdateCardPresentation.Button.installNow.rawValue): updater.installNow()
            case .button(UpdateCardPresentation.Button.later.rawValue): updater.installLater()
            case .button, .dismiss: break
            }
        }
        cardsObservation?.cancel()
        cardsObservation = Task {
            for await card in Observations({ () -> UpdateCard? in updater.card }) {
                let cards = card.map { [Self.sidebarCard($0)] } ?? []
                if model.cards != cards { model.cards = cards }
            }
        }
    }

    static func sidebarCard(_ card: UpdateCard) -> SidebarCard {
        let text = card.presentation
        return SidebarCard(id: updateCardID, title: text.title, detail: text.detail, progress: text.progress,
                           buttons: text.buttons.map { SidebarCard.Button(id: $0.rawValue, title: $0.title) },
                           dismissible: false, alwaysVisible: true, accent: text.accent)
    }
}
