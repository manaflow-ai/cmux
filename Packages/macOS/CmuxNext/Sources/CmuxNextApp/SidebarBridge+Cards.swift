import Foundation
import CmuxNextActions
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

extension SidebarBridge {
    func observeCards() {
        cardsObservation?.cancel()
        cardsObservation = SidebarCardFeed.start(model: model, updater: services.updater, window: state, registry: services.registry)
    }
}

/// The R114 card stack's content (a check the user asked for, the test-feed
/// notice, announcements; What's New is the sidebar's top item now) and the
/// staged update card (UPDATE-CARD). Card actions go back to their owners.
@MainActor
enum SidebarCardFeed {
    static let updateCardID = "update"
    static let testFeedCardID = "test-feed"
    /// Announcement cards are `announcement:<id>`.
    static let announcementPrefix = "announcement:"

    /// The cards, and with `window` its What's New item (SidebarWhatsNewItemFeed):
    /// one task, so the bridge cancels both together. `registry` gives the
    /// tip card its action's shortcut.
    static func start(model: SidebarModel, updater: UpdaterService, window: WindowState?, registry: ActionRegistry? = nil) -> Task<Void, Never> {
        let cards = start(model: model, updater: updater, registry: registry)
        guard let window else { return cards }
        let whatsNew = SidebarWhatsNewItemFeed.start(model: model, center: updater.whatsNew, state: window)
        return Task { await withTaskCancellationHandler { await cards.value } onCancel: { cards.cancel(); whatsNew.cancel() } }
    }

    static func start(model: SidebarModel, updater: UpdaterService, registry: ActionRegistry? = nil) -> Task<Void, Never> {
        model.onCardAction = { [weak updater] id, action in
            guard let updater else { return }
            if id.hasPrefix(announcementPrefix) {
                let announcement = String(id.dropFirst(announcementPrefix.count))
                if case .button(let actionID) = action, PageDescriptor.changelogTryItActions.contains(actionID) { updater.runAllowListedAction?(actionID) }
                if action == .dismiss { updater.dismissAnnouncement(announcement) }
                return
            }
            handle(id, action, updater: updater)
        }
        return Task {
            for await (cards, card, tip) in Observations({ () -> ([SidebarCard], SidebarUpdateCard?, SidebarTipCard?) in
                (cards(updater), updateCard(updater), tipCard(updater, registry: registry))
            }) {
                if model.cards != cards { model.cards = cards }
                if model.updateCard != card { model.updateCard = card }
                if model.tipCard != tip { model.tipCard = tip }
            }
        }
    }

    /// A link in the update card's popover (a pull request, the release
    /// notes): a browser tab in the active window's focused pane, like a
    /// Cmd-click on a terminal link; with no window it waits for one.
    static func openUpdateLink(_ url: URL, services: AppServices) {
        guard url.scheme == "https" else { return }
        if let pane = services.windows.active?.focusedPane {
            pane.newBrowserTab(url: url)
        } else {
            services.externalOpen.perform(.browserTab(url))
        }
    }

    static func handle(_ id: String, _ action: SidebarCardAction, updater: UpdaterService) {
        switch (id, action) {
        case (testFeedCardID, .button):
            try? updater.useTestFeed(nil, pinned: false)
        case (updateCardID, .open):
            updater.cardClicked()
        default:
            break
        }
    }

    /// The "Did you know" card (BOTTOM-LEFT-CARDS K1): today's tip with its
    /// action's shortcut; nil while the update card shows (one card at a time).
    static func tipCard(_ updater: UpdaterService, registry: ActionRegistry?) -> SidebarTipCard? {
        guard updater.readyCard == nil, let tip = updater.tip, tip.id.isEmpty else { return nil }  // red
        return SidebarTipCard(id: tip.id, eyebrow: UpdaterService.tipEyebrow, title: tip.title, benefit: tip.benefit,
                              shortcut: registry?.shortcutDisplay(for: ActionID(rawValue: tip.action)),
                              tryTitle: UpdaterService.announcementActionTitle, dismissLabel: UpdaterService.tipDismissLabel)
    }

    /// The staged update card (UPDATE-CARD; nil while checking or downloading).
    static func updateCard(_ updater: UpdaterService) -> SidebarUpdateCard? {
        guard let card = updater.readyCard else { return nil }
        let notes = card.notes
        let changes = notes.changes.map { SidebarUpdateCard.Change(title: $0.title, author: $0.author, linkTitle: $0.prLabel, url: $0.url) }
        return SidebarUpdateCard(
            title: card.title, buttonTitle: card.buttonTitle, isEnabled: !card.isInstalling,
            automaticUpdatesTitle: card.automaticUpdatesTitle, automaticUpdates: card.automaticUpdates,
            notes: SidebarUpdateCard.Notes(headline: notes.headline, keepsRunning: notes.keepsRunning,
                                           whatsChangedTitle: notes.whatsChangedTitle, changes: changes,
                                           moreTitle: notes.moreTitle, moreURL: notes.moreURL))
    }

    /// The update card first, then the test-feed notice while one is active.
    static func cards(_ updater: UpdaterService) -> [SidebarCard] {
        var cards = updater.card.map { [sidebarCard($0)] } ?? []
        for item in updater.announcements {
            let buttons = item.action.flatMap { id in
                PageDescriptor.changelogTryItActions.contains(id) ? [SidebarCard.Button(id: id, title: UpdaterService.announcementActionTitle)] : nil
            } ?? []
            cards.append(SidebarCard(id: announcementPrefix + item.id, title: item.title, detail: item.detail, buttons: buttons,
                                     dismissible: true, alwaysVisible: false))
        }
        if let text = updater.testFeedCardText {
            cards.append(SidebarCard(id: testFeedCardID, title: text.title, detail: text.detail,
                                     buttons: [SidebarCard.Button(id: "use-real-feed", title: text.useRealFeed)],
                                     dismissible: false, alwaysVisible: true))
        }
        return cards
    }

    static func sidebarCard(_ card: UpdateCard) -> SidebarCard {
        let text = card.presentation
        return SidebarCard(id: updateCardID, title: text.title, detail: text.detail, progress: text.progress,
                           dismissible: false, alwaysVisible: true)
    }
}
