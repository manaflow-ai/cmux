import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextFeed
import CmuxNextHome

/// Chief Home's pinned Needs you section (Leo, via his Chief: "a pinned Needs you view in Chief
/// Home, Feed and iPhone listing items waiting on Leo (PRs held for his trial like #30817,
/// sign-ins, approvals, consent cards)"). It is a view on the Feed's own model
/// (``FeedModel/needsYou``, the requests the Feed pins), never a second store; its answers are
/// the Feed's (``FeedNeedsYouView``).
@MainActor
enum HomeNeedsYou {
    /// A Chief's conversation shows the section while anything waits; any other conversation never.
    static func shows(isChief: Bool, waiting: Int) -> Bool { isChief && waiting > 0 }

    /// The section over the app's Feed, wired to open what a click names.
    static func makeSection(services: AppServices) -> FeedNeedsYouView {
        let model = services.feed.model
        // The Feed's own hooks: a request's Sign In / Open answers and its row's who and where.
        // Once: the Inbox page installs the same hooks when it is made.
        if model.onOpenItem == nil { FeedGitHubActions.install(on: model, services: services) }
        if model.place == nil { model.place = FeedPlace.lookup(services.daemon.store.place) }
        let section = FeedNeedsYouView(model: model)
        section.onOpen = { [weak services] item in
            if let services { open(item, services: services) }
        }
        section.onShowAll = { [weak services] in
            if let services { showFeed(services) }
        }
        return section
    }

    /// A click on a request opens its source: its link (a pull request, a sign-in page) through the
    /// Feed's open; else the tab or chat that asked; else the Feed with it selected.
    static func open(_ item: FeedItem, services: AppServices) {
        let model = services.feed.model
        if item.context.url != nil {
            model.open(item.id)
            return
        }
        model.select(item.id)
        let store = services.daemon.store, at = item.context
        let tab = at.tab.flatMap(store.tab(idOrResource:))
            ?? at.terminal.flatMap { store.tab(terminalResource: ResourceID(rawValue: $0)) }
            ?? at.acpSession.flatMap { store.tab(agentSession: $0) }
        if let tab, services.revealTab(tab.id) { return }
        showFeed(services)
    }

    /// The Feed's Inbox page, in the active window.
    static func showFeed(_ services: AppServices) {
        try? (services.pages.provider(.inbox) as? FeedPageService)?.open(focus: true)
    }
}

extension HomeHostView {
    /// While this Home shows a Chief's conversation, one observation of whether the Feed has open
    /// requests puts the section under the header or takes it away; the section observes its own
    /// rows. No polling, no timer: it wakes only on a Feed change. Restarted when the conversation
    /// becomes (or stops being) a Chief's; cancelled with the view (deinit).
    func watchNeedsYou() {
        needsYouWatch?.cancel()
        needsYouWatch = nil
        guard isChief else { return transcript.setPinnedSection(nil) }
        let services = control.services
        let feed = services.feed
        let model = feed.model
        // task-owner: lives while this Home shows a Chief (cancelled on the next change and in deinit); event-driven (Observation)
        needsYouWatch = Task { [weak self] in
            // The Feed's mirror runs once the account is signed in (the Feed panel and sidebar start it the same way).
            feed.startIfSignedIn()
            for await shows in ObservationStream({ HomeNeedsYou.shows(isChief: true, waiting: model.needsYou.count) }) {
                guard let self else { return }
                if !shows {
                    transcript.setPinnedSection(nil)
                } else if transcript.pinnedSection == nil {
                    let section = HomeNeedsYou.makeSection(services: services)
                    section.onHeightChange = { [weak transcript] in transcript?.pinnedSectionDidResize() }
                    transcript.setPinnedSection(section)
                }
            }
        }
    }
}
