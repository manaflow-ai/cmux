import CmuxNextDaemon
public import CmuxNextFeed
public import CmuxNextHome
import CmuxNextSettings

extension HomeNativeTranscriptView: FeedPinnedSectionHost {}

extension HomeHostView {
    /// A Chief's pinned Needs you section (``FeedNeedsYouPin``) over the app's Feed; none for any other conversation.
    func watchNeedsYou() {
        needsYouWatch?.cancel()
        needsYouWatch = nil
        guard isChief else { return transcript.setPinnedSection(nil) }
        let services = control.services, model = services.feed.model, store = services.daemon.store
        // Off by default (`feed.needsYouInChief`): the Feed always lists the requests; the pinned card is opt-in.
        let pin = FeedNeedsYouPin(model: model, isEnabled: { [weak services] in
            services?.settings?.snapshot.homeNeedsYouInChief ?? HomeNeedsYouSetting.fallback
        }, prepare: { [weak services] in
            guard let services else { return }
            // Once: the Inbox page installs the same hooks when it is made.
            if model.onOpenItem == nil { FeedGitHubActions.install(on: model, services: services) }
            if model.place == nil { model.place = FeedPlace.lookup(services.daemon.store.place) }
        }, reveal: { [weak services] at in
            let tab = at.tab.flatMap(store.tab(idOrResource:)) ?? at.terminal.flatMap { store.tab(terminalResource: ResourceID(rawValue: $0)) }
                ?? at.acpSession.flatMap { store.tab(agentSession: $0) }
            return tab.map { services?.revealTab($0.id) == true } ?? false
        }, showFeed: { [weak services] in try? (services?.pages.provider(.inbox) as? FeedPageService)?.open(focus: true) })
        services.feed.startIfSignedIn() // the Feed's mirror runs once the account is signed in, as the Feed panel starts it
        needsYouWatch = pin.watch(host: transcript)
    }
}
