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

/// The R114 card stack's content (the test-feed notice, announcements;
/// What's New is the sidebar's top item now), the staged update card
/// (UPDATE-CARD) and the shared notice card (the update status, else the
/// "Did you know" tip). Card actions go back to their owners.
@MainActor
enum SidebarCardFeed {
    static let updateCardID = "update"
    /// Tip notices are `tip:<tip id>`; their one button is `try`.
    static let tipPrefix = "tip:"
    static let tryActionID = "try"
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
            for await (cards, card, updated, notice) in Observations({ () -> ([SidebarCard], SidebarUpdateCard?, SidebarUpdatedCard?, SidebarNoticeCard?) in
                (cards(updater), updateCard(updater), updatedCard(updater), noticeCard(updater, registry: registry))
            }) {
                if model.cards != cards { model.cards = cards }
                if model.updateCard != card { model.updateCard = card }
                if model.updatedCard != updated { model.updatedCard = updated }
                if model.noticeCard != notice { model.noticeCard = notice }
            }
        }
    }

    /// The bottom-left cards' intents (UPDATE-CARD, BOTTOM-LEFT-CARDS K1): the
    /// update card's button installs and relaunches (the relaunch keeps every
    /// session), its checkbox writes the setting, a popover link opens; a
    /// notice's buttons go to its owner (the update status, a tip's Try It),
    /// its x hides it.
    static func handle(_ intent: SidebarIntent, services: AppServices) {
        switch intent {
        case .installUpdate: services.updater.installClicked()
        case .setAutomaticUpdates(let on): services.updater.setAutomaticUpdates(on)
        case .openUpdateLink(let url): openUpdateLink(url, services: services)
        case .noticeAction(let card, let action): noticeAction(card, action, services: services)
        case .dismissNotice(let card): dismissNotice(card, updater: services.updater)
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

    /// The "cmux Updated!" card while it shows (nil while an update is staged
    /// or an update status shows: they have the slot).
    static func updatedCard(_ updater: UpdaterService) -> SidebarUpdatedCard? {
        guard updater.readyCard == nil, updater.card == nil, updater.whatsNew.showsUpdatedCard else { return nil }
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
        default:
            break
        }
    }

    /// A notice button: the update status's actions (Release Notes opens
    /// like a popover link), a tip's Try It.
    static func noticeAction(_ card: String, _ action: String, services: AppServices) {
        let updater = services.updater
        if card == updateCardID, let action = UpdateCardAction(rawValue: action) {
            if action == .releaseNotes, let url = updater.cardReleaseNotesURL {
                openUpdateLink(url, services: services)
            } else {
                updater.performCardAction(action)
            }
        } else if card.hasPrefix(tipPrefix), action == tryActionID {
            updater.tryTip(String(card.dropFirst(tipPrefix.count)))
        }
    }

    /// A notice's x: the update status hides; a tip never shows again.
    static func dismissNotice(_ card: String, updater: UpdaterService) {
        if card == updateCardID {
            updater.dismissCard()
        } else if card.hasPrefix(tipPrefix) {
            updater.dismissTip(String(card.dropFirst(tipPrefix.count)))
        }
    }

    /// The shared notice card (Lawrence 2026-10-09): the update status (a
    /// check's progress and result, a found update) first, else today's
    /// "Did you know" tip with its action's shortcut; nil while the staged
    /// update card shows, and the tip also waits for the "cmux Updated!"
    /// card (one card at a time).
    static func noticeCard(_ updater: UpdaterService, registry: ActionRegistry?) -> SidebarNoticeCard? {
        guard updater.readyCard == nil else { return nil }
        if let status = updateNotice(updater) { return status }
        guard !updater.whatsNew.showsUpdatedCard, let tip = updater.tip else { return nil }
        return SidebarNoticeCard(id: tipPrefix + tip.id, eyebrow: UpdaterService.tipEyebrow, title: tip.title, detail: tip.benefit,
                                 actions: [SidebarNoticeCard.Action(id: tryActionID, title: UpdaterService.announcementActionTitle)],
                                 shortcut: registry?.shortcutDisplay(for: ActionID(rawValue: tip.action)),
                                 dismissLabel: UpdaterService.tipDismissLabel)
    }

    /// The update status as a notice: one model (``UpdateCard``), its icon,
    /// title, detail and actions.
    static func updateNotice(_ updater: UpdaterService) -> SidebarNoticeCard? {
        guard let shown = updater.cardPresentation else { return nil }
        let progress: SidebarNoticeCard.Progress? = shown.showsProgress ? (shown.progress.map { .fraction($0) } ?? .indeterminate) : nil
        return SidebarNoticeCard(id: updateCardID, symbol: shown.symbol, title: shown.title, detail: shown.detail, progress: progress,
                                 actions: shown.actions.map { SidebarNoticeCard.Action(id: $0.rawValue, title: $0.title, prominent: $0.isProminent) },
                                 dismissLabel: shown.dismissible ? UpdaterService.cardDismissLabel : nil)
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

    /// The announcements, then the test-feed notice while one is active. The
    /// update status is the notice card, never a stack card.
    static func cards(_ updater: UpdaterService) -> [SidebarCard] {
        var cards: [SidebarCard] = []
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
}
