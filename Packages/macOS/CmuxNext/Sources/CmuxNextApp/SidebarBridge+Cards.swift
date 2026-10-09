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
            for await (cards, card, updated, tip) in Observations({ () -> ([SidebarCard], SidebarUpdateCard?, SidebarUpdatedCard?, SidebarTipCard?) in
                (cards(updater), updateCard(updater), updatedCard(updater), tipCard(updater, registry: registry))
            }) {
                if model.cards != cards { model.cards = cards }
                if model.updateCard != card { model.updateCard = card }
                if model.updatedCard != updated { model.updatedCard = updated }
                if model.tipCard != tip { model.tipCard = tip }
            }
        }
    }

    /// The bottom-left cards' intents (UPDATE-CARD, BOTTOM-LEFT-CARDS K1): the
    /// update card's button installs and relaunches (the relaunch keeps every
    /// session), its checkbox writes the setting, a popover link opens; the
    /// tip card's Try It runs the feature, its x hides the tip.
    static func handle(_ intent: SidebarIntent, services: AppServices) {
        switch intent {
        case .installUpdate: services.updater.installClicked()
        case .setAutomaticUpdates(let on): services.updater.setAutomaticUpdates(on)
        case .openUpdateLink(let url): openUpdateLink(url, services: services)
        case .tryTip(let id): services.updater.tryTip(id)
        case .dismissTip(let id): services.updater.dismissTip(id)
        case .openWhatsNew, .shareCmux, .dismissUpdated: route(intent, registry: services.registry, updater: services.updater)
        default: break
        }
    }

    /// The "cmux Updated!" card (cx-7py7): its rows run the palette's own
    /// actions as the user's (`updates.whatsNew` opens the page and marks
    /// this version seen; `app.shareCmux` opens the modal); its x marks this
    /// version seen, so the card and the What's New dot go together.
    static func route(_ intent: SidebarIntent, registry: ActionRegistry, updater: UpdaterService) {
        switch intent {
        case .openWhatsNew: _ = registry.perform("updates.whatsNew", invocation: ActionInvocation(origin: .user))
        case .shareCmux: _ = registry.perform("app.shareCmux", invocation: ActionInvocation(origin: .user))
        case .dismissUpdated: updater.whatsNew.dismissUpdated()
        default: break
        }
    }

    /// The "cmux Updated!" card while it shows (nil while an update is staged:
    /// the update card has the slot).
    static func updatedCard(_ updater: UpdaterService) -> SidebarUpdatedCard? {
        guard updater.readyCard == nil, updater.whatsNew.showsUpdatedCard else { return nil }
        return SidebarUpdatedCard(title: UpdaterService.updatedCardTitle, whatsNewTitle: UpdaterService.updatedCardWhatsNewTitle,
                                  shareTitle: UpdaterService.updatedCardShareTitle, dismissLabel: UpdaterService.updatedCardDismissLabel)
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
    /// action's shortcut; nil while the update card or the "cmux Updated!"
    /// card shows (one card at a time; the tip waits).
    static func tipCard(_ updater: UpdaterService, registry: ActionRegistry?) -> SidebarTipCard? {
        guard updater.readyCard == nil, !updater.whatsNew.showsUpdatedCard, let tip = updater.tip else { return nil }
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
