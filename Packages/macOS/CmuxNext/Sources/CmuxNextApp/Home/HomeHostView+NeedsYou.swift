import AppKit
import CmuxNextFeedClient
import CmuxNextHome
import CmuxNextSettings

extension HomeNativeTranscriptView: FeedPinnedSectionHost {}

extension HomeHostView {
    /// A Chief's pinned Needs you section (the Feed page on `#/needs-you`, ``FeedNeedsYouSection``)
    /// while Settings > Notifications > Feed > Pin Needs You in Chief is on and something waits; none
    /// for any other conversation.
    func watchNeedsYou() {
        needsYouWatch?.cancel()
        needsYouWatch = nil
        guard isChief else { return transcript.setPinnedSection(nil) }
        let services = control.services
        let isEnabled = HomeNeedsYouSetting.reader { [weak services] in services?.settings } // opt-in, off by default
        needsYouWatch = FeedNeedsYouSection.watch(feed: services.feed.daemon, isEnabled: isEnabled, host: transcript) { [weak services] in
            services.flatMap { PageFactory(services: $0).feedWebPage(route: "#/needs-you") }.map { p in FeedNeedsYouSection(page: p, zoom: { [weak p] in p?.pageZoom ?? 1 }) { p.onZoomChange = $0 } }
        }
    }
}
