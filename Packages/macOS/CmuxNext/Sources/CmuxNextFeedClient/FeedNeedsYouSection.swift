package import AppKit
import CmuxNextCompat

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
@MainActor
package final class FeedNeedsYouSection: NSView {
    package static let padding: CGFloat = 8
    package static let headerHeight: CGFloat = 24
    package static let rowHeight: CGFloat = 40
    package static let rows = 3

    /// How many requests wait (0 hides the section).
    package var waiting = 0 {
        didSet { if waiting != oldValue { resized() } }
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

    /// The height in points the section's content takes for `waiting` requests at the page's `zoom`.
    package static func height(waiting: Int, zoom: CGFloat = 1) -> CGFloat {
        waiting > 0 ? ceil((padding * 2 + headerHeight + rowHeight * CGFloat(min(waiting, rows))) * zoom) : 0
    }

    override package var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height(waiting: waiting, zoom: zoom)) }
    override package var fittingSize: NSSize { NSSize(width: frame.width, height: Self.height(waiting: waiting, zoom: zoom)) }

    private func resized() {
        invalidateIntrinsicContentSize()
        onResize?()
    }

    /// While a Chief's conversation shows: the setting, read inside an observation so it switches live,
    /// and while it is on, the daemon's needs-you count, read again on each feed change, put the section
    /// under `host`'s header or take it away. No polling, no timer. The caller cancels the task when the
    /// conversation changes.
    package static func watch(feed: FeedDaemonClient, isEnabled: @escaping () -> Bool, host: any FeedPinnedSectionHost,
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
                    // Another account's count goes at once, before its own snapshot.
                    var shown = FeedAccountProjection<Never>()
                    for await _ in feed.changes() {
                        guard let view = try? await feed.view(.needsYou), !Task.isCancelled, let host else { continue }
                        // Not settled: keep what shows; an empty answer then is not "nothing waits".
                        guard shown.settled(view, clear: { host.setPinnedSection(nil) }) else { continue }
                        show(waiting: view.items(in: "needs_you").count, in: host, makeSection: makeSection)
                    }
                }
            }
        }
    }

    private static func show(waiting: Int, in host: any FeedPinnedSectionHost, makeSection: () -> FeedNeedsYouSection?) {
        if waiting == 0 { return host.setPinnedSection(nil) }
        if let section = host.pinnedSection as? FeedNeedsYouSection {
            section.waiting = waiting // a change asks the host to measure again (onResize)
            return
        }
        guard let section = makeSection() else { return }
        section.waiting = waiting
        section.onResize = { [weak host] in host?.pinnedSectionDidResize() }
        host.setPinnedSection(section)
    }
}
