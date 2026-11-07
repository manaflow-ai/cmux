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
        let isEnabled = HomeNeedsYouSetting.reader { [weak services] in services?.settings } // opt-in, off by default
        let pin = FeedNeedsYouPin(model: model, isEnabled: isEnabled, prepare: { [weak services] in
            guard let services else { return }
            // Once: the Inbox page installs the same hooks when it is made.
            if model.onOpenItem == nil { FeedGitHubActions.install(on: model, services: services) }
            if model.place == nil { model.place = FeedPlace.lookup(services.daemon.store.place) }
        }, reveal: { [weak services] at in
            store.tab(reported: at.tab, terminal: at.terminal, agentSession: at.acpSession).map { services?.revealTab($0.id) == true } ?? false
        }, showFeed: { [weak services] in try? (services?.pages.provider(.inbox) as? FeedPageService)?.open(focus: true) })
        services.feed.startIfSignedIn() // the Feed's mirror runs once the account is signed in, as the Feed panel starts it
        needsYouWatch = pin.watch(host: transcript)
    }
}
