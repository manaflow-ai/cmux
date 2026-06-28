/// Owns the download-activity tally for one `BrowserPanel`: the active-download
/// count, the `wasDownloading -> isDownloading` edge it computes on each
/// begin/end, and the choice of which hidden-web-view discard hook to fire on
/// that edge. Pure decision logic; the live effects (publishing `isDownloading`
/// and scheduling/reevaluating the hidden-web-view discard) are forwarded to the
/// app-side ``BrowserDownloadActivityHosting``.
///
/// ``begin()`` bumps the count, derives `isDownloading = count > 0`, publishes it
/// through the host, and on the false->true edge reevaluates discard scheduling
/// with `"download.started"`. ``end()`` clamps the decrement at zero, derives
/// `isDownloading`, publishes it, and when it reaches zero schedules a discard
/// with `"download.finished"`. The caller-side main-thread hop stays app-side;
/// this coordinator assumes it runs on the main actor.
///
/// `@MainActor` because the published `isDownloading` and the discard scheduler
/// it drives are main-actor-bound and the owning panel is `@MainActor`, so every
/// forward stays a plain main-actor call.
@MainActor
public final class BrowserDownloadActivityCoordinator {
    /// The app-side host that owns the published `isDownloading` and the discard
    /// scheduler. Weak because the host (`BrowserPanel`) owns this coordinator
    /// strongly and outlives it, so this is non-nil whenever a method runs.
    public weak var host: (any BrowserDownloadActivityHosting)?

    /// Number of in-flight downloads (navigation + context menu). Source of truth
    /// for the published `isDownloading` flag, which the host mirrors; the
    /// invariant `isDownloading == (activeDownloadCount > 0)` lets ``begin()``
    /// read the pre-increment count as the legacy `wasDownloading`.
    public private(set) var activeDownloadCount: Int = 0

    public init() {}

    /// Records a started download: reads the pre-increment count as
    /// `wasDownloading`, bumps the count, publishes the resulting `isDownloading`,
    /// and on the false->true edge reevaluates hidden-web-view discard scheduling
    /// (legacy `beginDownloadActivity` body).
    public func begin() {
        guard let host else { return }
        let wasDownloading = activeDownloadCount > 0
        activeDownloadCount += 1
        let isDownloading = activeDownloadCount > 0
        host.setDownloadingActive(isDownloading)
        if !wasDownloading && isDownloading {
            host.reevaluateHiddenWebViewDiscardScheduling(reason: "download.started")
        }
    }

    /// Records a finished/failed download: clamps the decrement at zero, publishes
    /// the resulting `isDownloading`, and when it reaches zero schedules a
    /// hidden-web-view discard (legacy `endDownloadActivity` body).
    public func end() {
        guard let host else { return }
        activeDownloadCount = max(0, activeDownloadCount - 1)
        let isDownloading = activeDownloadCount > 0
        host.setDownloadingActive(isDownloading)
        if !isDownloading {
            host.scheduleHiddenWebViewDiscardIfNeeded(reason: "download.finished")
        }
    }

    /// Zeroes the active-download count (legacy `activeDownloadCount = 0` during a
    /// workspace-context reset). Does not touch the published `isDownloading`; the
    /// caller clears that app-side to match the legacy reset order.
    public func resetCount() {
        activeDownloadCount = 0
    }
}
