import CmuxNextCompat
import Foundation
import CmuxNextActions
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

extension SidebarBridge {
    func observeCards() {
        cardsObservation?.cancel()
        cardsObservation = SidebarCardFeed.start(model: model, updater: services.updater, window: state,
                                                 registry: services.registry, transfer: services.sessionTransfer)
    }
}

/// The bottom-left cards: the staged update card (UPDATE-CARD), the "cmux
/// Updated!" card and the shared notice card for every message to the user
/// (the update status, the test-feed notice, announcements, the "Did you
/// know" tip; What's New is the sidebar's top item). Card actions go back
/// to their owners.
@MainActor
enum SidebarCardFeed {
    static let updateCardID = "update"
    /// Tip notices are `tip:<tip id>`; their one button is `try`.
    static let tipPrefix = "tip:"
    static let tryActionID = "try"
    static let testFeedCardID = "test-feed"
    static let useRealFeedActionID = "use-real-feed"
    /// Announcement cards are `announcement:<id>`.
    static let announcementPrefix = "announcement:"
    static let continuityCardID = "session-continuity"
    static let continuityActionID = "move"

    /// The cards, and with `window` its What's New item (SidebarWhatsNewItemFeed):
    /// one task, so the bridge cancels both together. `registry` gives the
    /// tip card its action's shortcut.
    static func start(model: SidebarModel, updater: UpdaterService, window: WindowState?, registry: ActionRegistry? = nil,
                      transfer: SessionTransferService? = nil) -> Task<Void, Never> {
        let cards = start(model: model, updater: updater, registry: registry, transfer: transfer)
        guard window != nil else { return cards }
        let whatsNew = SidebarWhatsNewItemFeed.start(model: model, center: updater.whatsNew)
        return Task { await withTaskCancellationHandler { await cards.value } onCancel: { cards.cancel(); whatsNew.cancel() } }
    }

    static func start(model: SidebarModel, updater: UpdaterService, registry: ActionRegistry? = nil,
                      transfer: SessionTransferService? = nil) -> Task<Void, Never> {
        Task {
            for await (card, updated, notice) in ObservationStream({ () -> (SidebarUpdateCard?, SidebarUpdatedCard?, SidebarNoticeCard?) in
                (updateCard(updater), updatedCard(updater), noticeCard(updater, registry: registry, transfer: transfer))
            }) {
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
        case .noticeAction(let card, let action):
            noticeAction(card, action, updater: services.updater, transfer: services.sessionTransfer,
                         registry: services.registry, open: { openUpdateLink($0, services: services) })
        case .dismissNotice(let card): dismissNotice(card, updater: services.updater, transfer: services.sessionTransfer)
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
        guard updater.readyCard == nil, updater.card == nil, updater.testFeedURL == nil, updater.whatsNew.showsUpdatedCard else { return nil }
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

    /// A notice button: the update status's actions (Release Notes is a
    /// link `open` shows like a popover link), Use Real Feed, an
    /// announcement's allow-listed Try It, a tip's Try It.
    static func noticeAction(_ card: String, _ action: String, updater: UpdaterService,
                             transfer: SessionTransferService, registry: ActionRegistry, open: (URL) -> Void) {
        if card == updateCardID, let action = UpdateCardAction(rawValue: action) {
            if action == .releaseNotes, let url = updater.cardReleaseNotesURL {
                open(url)
            } else {
                updater.performCardAction(action)
            }
        } else if card == testFeedCardID, action == useRealFeedActionID {
            try? updater.useTestFeed(nil, pinned: false)
        } else if card == continuityCardID, action == continuityActionID {
            _ = registry.perform("session.moveHere", invocation: ActionInvocation(origin: .user))
        } else if card.hasPrefix(announcementPrefix), PageDescriptor.changelogTryItActions.contains(action) {
            updater.runAllowListedAction?(action)
        } else if card.hasPrefix(tipPrefix), action == tryActionID {
            updater.tryTip(String(card.dropFirst(tipPrefix.count)))
        }
    }

    /// A notice's x: the update status hides; an announcement or a tip never
    /// shows again. The test-feed notice has no x.
    static func dismissNotice(_ card: String, updater: UpdaterService, transfer: SessionTransferService) {
        if card == updateCardID {
            updater.dismissCard()
        } else if card == continuityCardID {
            transfer.dismissOffer()
        } else if card.hasPrefix(announcementPrefix) {
            updater.dismissAnnouncement(String(card.dropFirst(announcementPrefix.count)))
        } else if card.hasPrefix(tipPrefix) {
            updater.dismissTip(String(card.dropFirst(tipPrefix.count)))
        }
    }

    /// The shared notice card (Lawrence 2026-10-09), one message at a time:
    /// the update status (a check's progress and result, a found update),
    /// then the active test feed, then the newest announcement, then today's
    /// "Did you know" tip. Nil while the staged update card shows;
    /// announcements and the tip also wait for the "cmux Updated!" card.
    static func noticeCard(_ updater: UpdaterService, registry: ActionRegistry?, transfer: SessionTransferService? = nil) -> SidebarNoticeCard? {
        guard updater.readyCard == nil else { return nil }
        if let shown = updater.cardPresentation { return notice(shown) }
        if let text = updater.testFeedCardText {
            return SidebarNoticeCard(id: testFeedCardID, symbol: "testtube.2", title: text.title, detail: text.detail,
                                     actions: [SidebarNoticeCard.Action(id: useRealFeedActionID, title: text.useRealFeed)])
        }
        guard !updater.whatsNew.showsUpdatedCard else { return nil }
        if let offer = transfer?.offer {
            let detail = "\(offer.itemCount) session\(offer.itemCount == 1 ? "" : "s") are open in another cmux build."
            return SidebarNoticeCard(id: continuityCardID, symbol: "arrow.down.to.line", title: "Move my sessions here",
                                     detail: detail,
                                     actions: [SidebarNoticeCard.Action(id: continuityActionID, title: "Move Sessions")],
                                     dismissLabel: UpdaterService.cardDismissLabel)
        }
        if let item = updater.announcements.first {
            let actions = item.action.flatMap { id in
                PageDescriptor.changelogTryItActions.contains(id) ? [SidebarNoticeCard.Action(id: id, title: UpdaterService.announcementActionTitle)] : nil
            } ?? []
            return SidebarNoticeCard(id: announcementPrefix + item.id, symbol: "megaphone", title: item.title, detail: item.detail,
                                     actions: actions, dismissLabel: UpdaterService.cardDismissLabel)
        }
        guard let tip = updater.tip else { return nil }
        return SidebarNoticeCard(id: tipPrefix + tip.id, eyebrow: UpdaterService.tipEyebrow, title: tip.title, detail: tip.benefit,
                                 actions: [SidebarNoticeCard.Action(id: tryActionID, title: UpdaterService.announcementActionTitle)],
                                 shortcut: registry?.shortcutDisplay(for: ActionID(rawValue: tip.action)),
                                 dismissLabel: UpdaterService.tipDismissLabel)
    }

    /// The update status as a notice: one model (``UpdateCard``), its icon,
    /// title, detail and actions.
    static func notice(_ shown: UpdateCardPresentation) -> SidebarNoticeCard {
        let progress: SidebarNoticeCard.Progress? = shown.showsProgress ? (shown.progress.map { .fraction($0) } ?? .indeterminate) : nil
        return SidebarNoticeCard(id: updateCardID, symbol: shown.symbol, title: shown.title, detail: shown.detail, lines: shown.lines,
                                 progress: progress,
                                 actions: shown.actions.map { SidebarNoticeCard.Action(id: $0.rawValue, title: $0.title, prominent: $0.isProminent) },
                                 dismissLabel: shown.dismissible ? UpdaterService.cardDismissLabel : nil)
    }

    /// The staged update card (UPDATE-CARD; nil while checking or downloading).
    static func updateCard(_ updater: UpdaterService) -> SidebarUpdateCard? {
        guard let card = updater.readyCard else { return nil }
        let notes = card.notes
        let changes = notes.changes.map { SidebarUpdateCard.Change(title: $0.title, author: $0.author, linkTitle: $0.prLabel, url: $0.url) }
        return SidebarUpdateCard(
            title: card.title, detail: card.detail, lines: card.lines, releaseNotesTitle: card.releaseNotesTitle,
            releaseNotesURL: card.releaseNotesURL, buttonTitle: card.buttonTitle, isEnabled: !card.isInstalling,
            automaticUpdatesTitle: card.automaticUpdatesTitle, automaticUpdates: card.automaticUpdates,
            notes: SidebarUpdateCard.Notes(headline: notes.headline, keepsRunning: notes.keepsRunning,
                                           whatsChangedTitle: notes.whatsChangedTitle, changes: changes,
                                           moreTitle: notes.moreTitle, moreURL: notes.moreURL))
    }
}
