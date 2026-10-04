import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The R114 card stack: the update card (the updater's gate decides
/// whether one shows) and, later, what's new and announcements.
extension SidebarBridge {
    static let updateCardID = "update"
    static let testFeedCardID = "test-feed"

    func observeCards() {
        let updater = services.updater
        let model = model
        model.onCardAction = { [weak updater] id, action in
            guard let updater else { return }
            if id == Self.testFeedCardID {
                if case .button = action { try? updater.useTestFeed(nil, pinned: false) }
                return
            }
            guard id == Self.updateCardID else { return }
            switch action {
            case .open: updater.cardClicked()
            case .button(UpdateCardPresentation.Button.installNow.rawValue): updater.installNow()
            case .button(UpdateCardPresentation.Button.later.rawValue): updater.installLater()
            case .button, .dismiss: break
            }
        }
        cardsObservation?.cancel()
        cardsObservation = Task {
            for await cards in Observations({ () -> [SidebarCard] in Self.cards(updater) }) {
                if model.cards != cards { model.cards = cards }
            }
        }
    }

    /// The update card first, then the test-feed notice while one is active.
    static func cards(_ updater: UpdaterService) -> [SidebarCard] {
        var cards = updater.card.map { [sidebarCard($0)] } ?? []
        if let text = updater.testFeedCardText {
            cards.append(SidebarCard(id: testFeedCardID, title: text.title, detail: text.detail,
                                     buttons: [SidebarCard.Button(id: "use-real-feed", title: text.useRealFeed)],
                                     dismissible: false, alwaysVisible: true, accent: false))
        }
        return cards
    }

    static func sidebarCard(_ card: UpdateCard) -> SidebarCard {
        let text = card.presentation
        return SidebarCard(id: updateCardID, title: text.title, detail: text.detail, progress: text.progress,
                           buttons: text.buttons.map { SidebarCard.Button(id: $0.rawValue, title: $0.title) },
                           dismissible: false, alwaysVisible: true, accent: text.accent)
    }
}
