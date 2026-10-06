import CmuxNextPages
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

extension SidebarBridge {
    func observeCards() {
        cardsObservation?.cancel()
        cardsObservation = SidebarCardFeed.start(model: model, updater: services.updater)
    }
}

/// The R114 card stack's content: the update card (the updater's gate
/// decides whether one shows), the test-feed notice, and later what's new
/// and announcements. Card actions go back to their owners.
@MainActor
enum SidebarCardFeed {
    static let updateCardID = "update"
    static let testFeedCardID = "test-feed"
    static let whatsNewCardID = "whats-new"
    /// Announcement cards are `announcement:<id>`.
    static let announcementPrefix = "announcement:"

    static func start(model: SidebarModel, updater: UpdaterService) -> Task<Void, Never> {
        model.onCardAction = { [weak updater] id, action in
            guard let updater else { return }
            if id.hasPrefix(announcementPrefix) {
                let announcement = String(id.dropFirst(announcementPrefix.count))
                if case .button(let actionID) = action, PageDescriptor.changelogTryItActions.contains(actionID) { updater.runAllowListedAction?(actionID) }
                if action == .dismiss { updater.dismissAnnouncement(announcement) }
                return
            }
            if id == whatsNewCardID {
                if action != .dismiss { _ = updater.openChangelog?() }
                updater.dismissWhatsNew()
                return
            }
            handle(id, action, updater: updater)
        }
        return Task {
            for await cards in Observations({ () -> [SidebarCard] in cards(updater) }) {
                if model.cards != cards { model.cards = cards }
            }
        }
    }

    static func handle(_ id: String, _ action: SidebarCardAction, updater: UpdaterService) {
        switch (id, action) {
        case (testFeedCardID, .button):
            try? updater.useTestFeed(nil, pinned: false)
        case (updateCardID, .open):
            updater.cardClicked()
        case (updateCardID, .button(UpdateCardPresentation.Button.installNow.rawValue)):
            updater.installNow()
        case (updateCardID, .button(UpdateCardPresentation.Button.later.rawValue)):
            updater.installLater()
        default:
            break
        }
    }

    /// The update card first, then the test-feed notice while one is active.
    static func cards(_ updater: UpdaterService) -> [SidebarCard] {
        var cards = updater.card.map { [sidebarCard($0)] } ?? []
        for item in updater.announcements {
            let buttons = item.action.flatMap { id in
                PageDescriptor.changelogTryItActions.contains(id) ? [SidebarCard.Button(id: id, title: UpdaterService.announcementActionTitle)] : nil
            } ?? []
            cards.append(SidebarCard(id: announcementPrefix + item.id, title: item.title, detail: item.detail, buttons: buttons,
                                     dismissible: true, alwaysVisible: false, accent: false))
        }
        if let text = updater.whatsNewCardText {
            cards.append(SidebarCard(id: whatsNewCardID, title: text.title, detail: text.detail,
                                     dismissible: true, alwaysVisible: true, accent: false))
        }
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
                           dismissible: false, alwaysVisible: true)
    }
}
