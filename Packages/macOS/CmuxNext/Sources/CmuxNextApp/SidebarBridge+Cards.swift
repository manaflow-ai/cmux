import CmuxNextCompat
import Foundation
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextNowPlaying
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater
import CmuxNextWakeups
import Observation

extension SidebarBridge {
    func observeCards() {
        cards?.cancel()
        priority?.cancel()
        updateButton?.cancel()
        topItems?.cancel()
        let requests = services.cache.pageRequests
        nowPlayingFeed = model.followNowPlaying(services.nowPlayingSources, dismissal: requests.nowPlayingCard, settings: { [weak services] in services?.settings }, registry: services.registry,
                                                 queries: services.workspaceQueries, on: services.mainWork)
        // The Priority view (`sidebar.priorityView.*`) ends with the cards.
        priority = SidebarPriorityFeed(services: services).start(container.sidebarView)
        cards = SidebarCardFeed.start(model: model, updater: services.updater, registry: services.registry, asks: services.machineAsks, on: services.mainWork)
        // The titlebar's quiet Update Available button (#25283).
        updateButton = SidebarCardFeed.followAvailableUpdate(container.sidebarView, updater: services.updater, on: services.mainWork)
        // A window's sidebar also follows its top items (`SidebarModel.followTopItems`).
        topItems = state == nil ? nil : model.followTopItems(on: services.mainWork)
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
    /// Tip notices are `tip:<tip id>`; their one button is `try`, their x's menu `UpdaterService.tipMenu`.
    static let tipPrefix = "tip:"
    static let tryActionID = "try"
    static let testFeedCardID = "test-feed"
    static let useRealFeedActionID = "use-real-feed"
    /// Announcement cards are `announcement:<id>`.
    static let announcementPrefix = "announcement:"

    /// The update, updated and notice cards, in that order.
    typealias Cards = (SidebarUpdateCard?, SidebarUpdatedCard?, SidebarNoticeCard?)

    /// Keeps `model`'s cards current. They are the sidebar model's (its card views draw them): a service
    /// observation, `visible` for the updater's own changes, sooner for the person's. `registry` gives the
    /// tip card its action's shortcut. The caller holds the token; releasing it stops the cards.
    static func start(model: SidebarModel, updater: UpdaterService, registry: ActionRegistry? = nil, asks: SidebarAsks? = nil,
                      on work: MainWorkScheduler) -> ServiceObservation<Cards> {
        ServiceObservation(.visible, owner: "SidebarCardFeed.cards", on: work) { () -> Cards in
            (updateCard(updater), updatedCard(updater), asks?.card ?? noticeCard(updater, registry: registry))
        } apply: { cards in
            if model.updateCard != cards.0 { model.updateCard = cards.0 }
            if model.updatedCard != cards.1 { model.updatedCard = cards.1 }
            if model.noticeCard != cards.2 { model.noticeCard = cards.2 }
        }
    }

    /// The sidebar footer's quiet Update Available button (``UpdaterService/availableButton``) on `view`:
    /// a service observation, `visible`. The caller holds the token (the window's sidebar bridge,
    /// cancelled with the cards); releasing it stops the button following.
    static func followAvailableUpdate(_ view: SidebarView, updater: UpdaterService,
                                      on work: MainWorkScheduler) -> ServiceObservation<String?> {
        ServiceObservation(.visible, owner: "SidebarCardFeed.updateAvailable", on: work) { () -> String? in
            updater.availableButton?.label
        } apply: { [weak view] label in
            view?.showUpdateAvailable(label)
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
        case .downloadUpdate: services.updater.downloadClicked()
        case .setAutomaticUpdates(let on): services.updater.setAutomaticUpdates(on)
        case .openUpdateLink(let url): openUpdateLink(url, services: services)
        case .openUpdateChanges: _ = services.updater.openStagedChangelog()
        // A question waiting on the person (an agent's Cloud machine request, ``SidebarAsks``) takes its answer first.
        case .noticeAction(let card, let action) where !services.machineAsks.answer(card, action: action):
            noticeAction(card, action, updater: services.updater, open: { openUpdateLink($0, services: services) })
        case .dismissNotice(let card) where !services.machineAsks.answer(card, action: nil): dismissNotice(card, updater: services.updater)
        case .openWhatsNew, .dismissUpdated: route(intent, registry: services.registry, updater: services.updater)
        // The media card's x runs the menu's and the palette's Hide (one action, u2437).
        case .hideNowPlayingCard: _ = services.registry.perform("nowPlaying.hideCard", invocation: ActionInvocation(origin: .user))
        // Edit mode's Add Items (SidebarView+EditItems): Settings on the sidebar's rows (the sidebar
        // items are settings, not store items: extensibility-DESIGN.md).
        case .addItems: try? services.settingsWindow.show(section: nil, setting: "sidebar.showProjects", focus: true)
        default: break
        }
    }

    /// The "cmux Updated!" card (cx-7py7): its button runs the palette's
    /// `updates.whatsNew` as the user's (it opens the page and marks this
    /// version seen); its x marks this version seen, so the card and the
    /// What's New dot go together. Share cmux is the palette's (`app.shareCmux`).
    static func route(_ intent: SidebarIntent, registry: ActionRegistry, updater: UpdaterService) {
        switch intent {
        case .openWhatsNew: _ = registry.perform("updates.whatsNew", invocation: ActionInvocation(origin: .user))
        case .dismissUpdated: updater.whatsNew.dismissUpdated()
        default: break
        }
    }

    /// The "cmux Updated!" card while it shows (nil while an update is staged
    /// or an update status shows: they have the slot).
    static func updatedCard(_ updater: UpdaterService) -> SidebarUpdatedCard? {
        guard updater.readyCard == nil, updater.card == nil, updater.testFeedURL == nil, updater.whatsNew.showsUpdatedCard else { return nil }
        return SidebarUpdatedCard(title: UpdaterService.updatedCardTitle, whatsNewTitle: UpdaterService.updatedCardWhatsNewTitle,
                                  dismissLabel: UpdaterService.updatedCardDismissLabel)
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

    /// A notice button: the update status's actions (Release Notes is a link `open` shows like a popover
    /// link), the update cards' x menu, Use Real Feed, an announcement's Try It, a tip's Try It and x menu.
    static func noticeAction(_ card: String, _ action: String, updater: UpdaterService, open: (URL) -> Void) {
        if card == updateCardID || card == SidebarUpdateCard.cardID, let option = UpdateCardCloseOption(rawValue: action) {
            updater.closeUpdateCard(option)
        } else if card == updateCardID, let action = UpdateCardAction(rawValue: action) {
            if action == .releaseNotes, let url = updater.cardReleaseNotesURL {
                open(url)
            } else {
                updater.performCardAction(action)
            }
        } else if card == testFeedCardID, action == useRealFeedActionID {
            try? updater.useTestFeed(nil, pinned: false)
        } else if card.hasPrefix(announcementPrefix), PageDescriptor.changelogTryItActions.contains(action) {
            updater.runAllowListedAction?(action)
        } else if card.hasPrefix(tipPrefix) {
            updater.tipCardAction(String(card.dropFirst(tipPrefix.count)), action)
        }
    }

    /// A notice's x: the update status hides; an announcement or a tip never
    /// shows again. The test-feed notice has no x.
    static func dismissNotice(_ card: String, updater: UpdaterService) {
        if card == updateCardID {
            updater.dismissCard()
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
    static func noticeCard(_ updater: UpdaterService, registry: ActionRegistry?) -> SidebarNoticeCard? {
        guard updater.readyCard == nil else { return nil }
        if let shown = updater.cardPresentation { return notice(shown, asked: updater.flow.userAsked) }
        if let text = updater.testFeedCardText {
            return SidebarNoticeCard(id: testFeedCardID, symbol: "testtube.2", title: text.title, detail: text.detail,
                                     actions: [SidebarNoticeCard.Action(id: useRealFeedActionID, title: text.useRealFeed)])
        }
        guard !updater.whatsNew.showsUpdatedCard else { return nil }
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
                                 shortcut: registry?.shortcutDisplay(for: ActionID(rawValue: tip.action)), dismissLabel: UpdaterService.tipMenuLabel,
                                 dismissMenu: UpdaterService.tipMenu.map { SidebarNoticeCard.Action(id: $0.id, title: $0.title) }, shownAction: UpdaterService.tipShownAction, hiddenAction: UpdaterService.tipHiddenAction)
    }

    /// The update status as a notice: one model (``UpdateCard``), its icon,
    /// title, detail and actions. `asked`: the person asked to check, so the
    /// notice takes the slot from Now Playing.
    static func notice(_ shown: UpdateCardPresentation, asked: Bool = false) -> SidebarNoticeCard {
        let progress: SidebarNoticeCard.Progress? = shown.showsProgress ? (shown.progress.map { .fraction($0) } ?? .indeterminate) : nil
        // A found update gets the Hide button (remind me later on right-click); a result keeps the x.
        let closes = shown.actions.contains(.update)
        return SidebarNoticeCard(id: updateCardID, symbol: shown.symbol, title: shown.title, detail: shown.detail, lines: shown.lines, progress: progress,
                                 actions: shown.actions.map { SidebarNoticeCard.Action(id: $0.rawValue, title: $0.title, prominent: $0.isProminent) },
                                 dismissLabel: shown.dismissible ? (closes ? UpdaterService.updateCloseLabel : UpdaterService.cardDismissLabel) : nil,
                                 dismissTitle: closes && shown.dismissible ? UpdaterService.updateHideTitle : nil, dismissMenu: closes ? UpdaterService.updateCloseMenu.map(SidebarNoticeCard.Action.init) : [],
                                 userAsked: asked)
    }

    /// The staged update card (UPDATE-CARD; nil while checking or downloading).
    static func updateCard(_ updater: UpdaterService) -> SidebarUpdateCard? {
        updater.readyCard.map { updateCard($0) }
    }

    /// The sidebar's card for the updater's staged `card`.
    static func updateCard(_ card: UpdateReadyCard) -> SidebarUpdateCard {
        let notes = card.notes
        let changes = notes.changes.map { SidebarUpdateCard.Change(title: $0.title, author: $0.author, linkTitle: $0.prLabel, url: $0.url) }
        return SidebarUpdateCard(
            title: card.title, detail: card.detail, seeAllTitle: card.seeAllTitle, buttonTitle: card.buttonTitle, isEnabled: !card.isInstalling,
            automaticUpdatesTitle: card.automaticUpdatesTitle, automaticUpdates: card.automaticUpdates,
            notes: SidebarUpdateCard.Notes(headline: notes.headline, keepsRunning: notes.keepsRunning,
                                           whatsChangedTitle: notes.whatsChangedTitle, changes: changes,
                                           moreTitle: notes.moreTitle, moreURL: notes.moreURL),
            closeTitle: card.isInstalling ? nil : UpdaterService.updateHideTitle, closeLabel: UpdaterService.updateCloseLabel,
            closeAction: UpdaterService.updateHideAction, closeMenu: UpdaterService.updateCloseMenu.map(SidebarNoticeCard.Action.init))
    }
}
