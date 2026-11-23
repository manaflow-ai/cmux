package import AppKit
import CmuxNextCompat
import CmuxNextWakeups

/// A view that pins one section under its header (Chief Home's transcript): the pinned Needs you
/// section's host (``FeedNeedsYouSection``).
@MainActor
package protocol FeedPinnedSectionHost: AnyObject {
    var pinnedSection: NSView? { get }
    func setPinnedSection(_ view: NSView?)
    func pinnedSectionDidResize()
}

/// The pinned Needs you section's frame around the Feed page (Leo, via his Chief: "a pinned Needs you
/// view in Chief Home, Feed and iPhone listing items waiting on Leo"). The page draws the requests and
/// their answers; this only gives the transcript its height, from the daemon's count of what waits:
/// the header and one row per request up to ``rows``, the page counting the rest. The constants are
/// the page's CSS px (webviews/src/pages/feed/styles.css: `.feed-page[data-view="needs-you"]` and
/// `.feed-needs` pad 4 each, `.feed-needs-header` 24, `--feed-needs-row` 40), so the height is
/// their sum times the page's zoom (``zoom``), which follows `ui.scale` live.
///
/// The integrations hub's approvals (``FeedNeedsYouHub``) show above the requests as cards of
/// ``hubCardHeight`` each, up to ``hubRows``: they wait on the same person, and are answered there.
@MainActor
package final class FeedNeedsYouSection: NSView {
    package static let padding: CGFloat = 8
    package static let headerHeight: CGFloat = 24
    package static let rowHeight: CGFloat = 40
    package static let rows = 3
    /// A hub approval card (`--feed-hub-card` in styles.css) and how many show before the page counts the rest.
    package static let hubCardHeight: CGFloat = 84
    package static let hubRows = 2

    /// How many requests wait (0 hides the section).
    package var waiting = 0 {
        didSet { if waiting != oldValue { resized() } }
    }

    /// How many hub approval cards show (waiting, or answered until the next refresh).
    package var hubCards = 0 {
        didSet { if hubCards != oldValue { resized() } }
    }

    /// The page's zoom (`PageWebView.pageZoom`: `ui.scale` for the Feed page): one CSS px is this
    /// many points.
    package var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { resized() } }
    }

    /// Tells the pinned section's host to measure it again (set when it is pinned).
    package var onResize: (() -> Void)?

    package init(page: NSView) {
        super.init(frame: .zero)
        page.autoresizingMask = [.width, .height]
        page.frame = bounds
        addSubview(page)
    }

    /// The section around a page that zooms (the Feed's `PageWebView`): `zoom` reads its zoom now,
    /// `onZoomChange` installs the section's update as the page's zoom-change hook
    /// (`PageWebView.onZoomChange`, run after each `ui.scale` change), so the height follows live.
    package convenience init(page: NSView, zoom: @escaping @MainActor () -> Double, onZoomChange: (@escaping () -> Void) -> Void) {
        self.init(page: page)
        self.zoom = CGFloat(zoom())
        onZoomChange { [weak self] in self?.zoom = CGFloat(zoom()) }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { nil }

    /// The height in points the section's content takes for `waiting` requests and `hubCards` hub
    /// approval cards at the page's `zoom`.
    package static func height(waiting: Int, hubCards: Int = 0, zoom: CGFloat = 1) -> CGFloat {
        guard waiting > 0 || hubCards > 0 else { return 0 }
        let rows = rowHeight * CGFloat(min(waiting, rows)) + hubCardHeight * CGFloat(min(hubCards, hubRows))
        return ceil((padding * 2 + headerHeight + rows) * zoom)
    }

    override package var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height(waiting: waiting, hubCards: hubCards, zoom: zoom)) }
    override package var fittingSize: NSSize { NSSize(width: frame.width, height: Self.height(waiting: waiting, hubCards: hubCards, zoom: zoom)) }

    private func resized() {
        invalidateIntrinsicContentSize()
        onResize?()
    }

    /// While a Chief's conversation shows: the setting, read inside an observation so it switches live,
    /// and while it is on, the daemon's needs-you count, read again on each feed change, and the hub's
    /// card count, read inside an observation, put the section under `host`'s header or take it away.
    /// The feed is never polled; the hub has no push, so it is read again every ``FeedNeedsYouHub/interval``
    /// while the setting is on. The caller cancels the task when the conversation changes.
    package static func watch(feed: FeedDaemonClient, hub: FeedNeedsYouHub? = nil, isEnabled: @escaping () -> Bool, host: any FeedPinnedSectionHost,
                      makeSection: @escaping @MainActor () -> FeedNeedsYouSection?) -> Task<Void, Never> {
        // task-owner: the caller's (HomeHostView.needsYouWatch), cancelled on the next change and in its deinit; event-driven
        return Task { [weak host] in
            var reading: Task<Void, Never>?
            defer { reading?.cancel() }
            for await enabled in ObservationStream({ isEnabled() }) {
                reading?.cancel()
                reading = nil
                guard enabled else {
                    host?.setPinnedSection(nil)
                    continue
                }
                // task-owner: this watch's; cancelled when the setting turns off or the watch ends.
                reading = Task { [weak host] in
                    let counts = Counts()
                    let rereads = hub.map(HubRereads.init)
                    // task-owner: this reading's; the hub's count and its first read, cancelled with it.
                    let hubTasks: [Task<Void, Never>] = hub.map { hub in [
                        Task { [weak host] in
                            for await cards in ObservationStream(hub.cards) {
                                guard !Task.isCancelled, let host else { return }
                                counts.hub = cards
                                if counts.settled { show(counts, in: host, makeSection: makeSection) }
                            }
                        },
                        Task { await rereads?.read() },
                    ] } ?? []
                    defer {
                        hubTasks.forEach { $0.cancel() }
                        rereads?.stop()
                    }
                    // Another account's count goes at once, before its own snapshot.
                    var shown = FeedAccountProjection<Never>()
                    for await _ in feed.changes() {
                        guard let view = try? await feed.view(.needsYou), !Task.isCancelled, let host else { continue }
                        // Not settled: keep what shows; an empty answer then is not "nothing waits".
                        guard shown.settled(view, clear: { host.setPinnedSection(nil) }) else { continue }
                        counts.feed = view.items(in: "needs_you").count
                        counts.settled = true
                        show(counts, in: host, makeSection: makeSection)
                    }
                }
            }
        }
    }

    /// What one watch last read: the feed's count (once its snapshot settled) and the hub's cards.
    @MainActor
    private final class Counts {
        var feed = 0
        var hub = 0
        var settled = false
    }

    /// The hub's re-read: once now, then one deadline ``FeedNeedsYouHub/interval`` after each read
    /// (a one-shot ``DemandTimer`` armed again, not a loop), until the reading stops.
    @MainActor
    private final class HubRereads {
        private let hub: FeedNeedsYouHub
        private let timer = DemandTimer(owner: "feed.needs-you.hub-reread")
        private var stopped = false

        init(hub: FeedNeedsYouHub) { self.hub = hub }

        func read() async {
            guard !stopped else { return }
            await hub.refresh()
            guard !stopped else { return }
            timer.schedule(after: hub.interval) { @MainActor [weak self] in await self?.read() }
        }

        func stop() {
            stopped = true
            timer.cancel()
        }
    }

    private static func show(_ counts: Counts, in host: any FeedPinnedSectionHost, makeSection: () -> FeedNeedsYouSection?) {
        if counts.feed == 0, counts.hub == 0 { return host.setPinnedSection(nil) }
        if let section = host.pinnedSection as? FeedNeedsYouSection {
            section.waiting = counts.feed // a change asks the host to measure again (onResize)
            section.hubCards = counts.hub
            return
        }
        guard let section = makeSection() else { return }
        section.waiting = counts.feed
        section.hubCards = counts.hub
        section.onResize = { [weak host] in host?.pinnedSectionDidResize() }
        host.setPinnedSection(section)
    }
}

/// The integrations hub's approvals for the pinned Needs you section: how many cards show (read
/// inside an observation, so it follows the hub's state live) and a re-read of the hub, run when the
/// section starts and every `interval` after.
package struct FeedNeedsYouHub: Sendable {
    package var cards: @MainActor @Sendable () -> Int
    package var refresh: @MainActor @Sendable () async -> Void
    package var interval: Duration

    package init(cards: @escaping @MainActor @Sendable () -> Int, refresh: @escaping @MainActor @Sendable () async -> Void,
                 interval: Duration = .seconds(60)) {
        self.cards = cards
        self.refresh = refresh
        self.interval = interval
    }
}
