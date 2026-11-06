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
/// the header and one row per request up to ``rows``, the page counting the rest.
@MainActor
package final class FeedNeedsYouSection: NSView {
    package static let padding: CGFloat = 6
    package static let headerHeight: CGFloat = 22
    package static let rowHeight: CGFloat = 40
    package static let rows = 3

    /// How many requests wait (0 hides the section).
    package var waiting = 0 {
        didSet { if waiting != oldValue { invalidateIntrinsicContentSize() } }
    }

    package init(page: NSView) {
        super.init(frame: .zero)
        page.autoresizingMask = [.width, .height]
        page.frame = bounds
        addSubview(page)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { nil }

    /// The height the section's content takes for `waiting` requests.
    package static func height(waiting: Int) -> CGFloat {
        waiting > 0 ? padding * 2 + headerHeight + rowHeight * CGFloat(min(waiting, rows)) : 0
    }

    override package var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height(waiting: waiting)) }
    override package var fittingSize: NSSize { NSSize(width: frame.width, height: Self.height(waiting: waiting)) }

    /// While a Chief's conversation shows: the setting, read inside an observation so it switches live,
    /// and while it is on, the daemon's needs-you count, read again on each feed change, put the section
    /// under `host`'s header or take it away. No polling, no timer. The caller cancels the task when the
    /// conversation changes.
    package static func watch(feed: FeedDaemonClient, isEnabled: @escaping () -> Bool, host: any FeedPinnedSectionHost,
                      makePage: @escaping @MainActor () -> NSView?) -> Task<Void, Never> {
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
                    for await _ in feed.changes() {
                        guard let view = try? await feed.view(.needsYou), !Task.isCancelled, let host else { continue }
                        // Not loaded or not connected: keep what shows; an empty answer then is not "nothing waits".
                        guard view.isLive else { continue }
                        show(waiting: view.items(in: "needs_you").count, in: host, makePage: makePage)
                    }
                }
            }
        }
    }

    private static func show(waiting: Int, in host: any FeedPinnedSectionHost, makePage: () -> NSView?) {
        if waiting == 0 { return host.setPinnedSection(nil) }
        if let section = host.pinnedSection as? FeedNeedsYouSection {
            guard section.waiting != waiting else { return }
            section.waiting = waiting
            return host.pinnedSectionDidResize()
        }
        guard let page = makePage() else { return }
        let section = FeedNeedsYouSection(page: page)
        section.waiting = waiting
        host.setPinnedSection(section)
    }
}
