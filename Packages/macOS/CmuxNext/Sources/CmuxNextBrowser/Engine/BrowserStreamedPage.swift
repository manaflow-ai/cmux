public import AppKit
import CmuxNextWakeups

/// A tab whose page streams from another machine (a remote desktop, a remote browser page): no
/// engine and no view state, only a connection, a decoder and the last frame. It hibernates as a
/// cmux page does (`BrowserRestoreState.appPage` with its address, built again by the App's
/// `restoreAppPage`), under its own feature (`memoryDiscardRemoteTabs`): the discard closes the
/// stream and its decoder, the placeholder keeps the last frame, and showing the tab builds it
/// again, which connects, under that frame until the new stream's first one. Chrome's discard
/// keeps a tab's navigation entry and loads it again when it shows
/// (`TabLifecycleUnit::Discard`, chrome/browser/resource_coordinator/tab_lifecycle_unit.cc).
public protocol BrowserStreamedPage: BrowserHibernationSource, BrowserWakeStandIn {
    /// The address the App builds this page again from, for what it shows now; nil while a page
    /// built from it would not show the same (the person stopped the session, it ended or failed,
    /// or the remote page has history a new runtime would lose): then it is never discarded.
    @MainActor var wakeAddress: URL? { get }
}

extension BrowserStreamedPage {
    public var supportsHibernation: Bool { wakeAddress != nil }
    /// A stream is never a form submission's result.
    public var showsFormSubmission: Bool { false }
    /// A stream shows no web notifications.
    public var allowsNotifications: Bool { false }

    public func hibernationState() -> BrowserRestoreState? {
        wakeAddress.map { BrowserRestoreState.appPage(BrowserAppPageState(url: $0)) }
    }
}

/// A woken page's last frame over its view until the page presents its own first frame
/// (`BrowserWakeStandIn` for pages with no engine paint signal, such as a remote stream). The page
/// removes it on that frame, on a failure, and on close; the cap removes it too. It holds the
/// picture only while it shows.
@MainActor public final class BrowserWakeCover {
    /// The longest a woken stream's last frame covers it: a reconnect (the transport, the host's
    /// open, a keyframe), not a paint (`BrowserWakeStandIn.wakeCoverCap`).
    public static let reconnectCap: Duration = .seconds(3)

    private struct Shown {
        let view: BrowserPictureView
        let picture: CGImage
        let decoded: Bool
        let cap: Duration
        let clock: any Clock<Duration>
        let timer: DemandTimer
    }

    private var shown: Shown?

    public init() {}

    /// The picture covers the page now.
    public var isShown: Bool { shown != nil }

    /// The pixels the cover draws now; nil while it is not shown, or decodes its picture.
    public var shownPixels: CGImage? { shown?.view.decodedPicture }

    /// Covers `host` with `picture` until `remove()` or until `cap` passes on `clock`.
    public func show(_ picture: CGImage, decoded: Bool, in host: NSView, cap: Duration, clock: any Clock<Duration>) {
        remove()
        // Pixels already decoded cover the page from the swap's first frame.
        let view = decoded ? BrowserPictureView(decoded: picture) : BrowserPictureView(picture: { picture })
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view, positioned: .above, relativeTo: nil)
        // timer-class-allow: the cap runs on the clock BrowserWakeStandIn hands in (WebKitTab's cap does the same)
        let timer = DemandTimer(owner: "BrowserWakeCover", clock: clock)
        // Justified delay: the cap of a stand-in, not a poll; the first frame, a failure or a close cancels it.
        timer.scheduleOnMain(after: cap) { [weak self, weak view] in
            guard let self, let view, self.shown?.view === view else { return }
            self.remove()
        }
        shown = Shown(view: view, picture: picture, decoded: decoded, cap: cap, clock: clock, timer: timer)
    }

    /// The page that replaces this one shows the cover in its place (a machine's browser that
    /// started); this cover goes. Nothing when it is not shown.
    public func handOver(to page: any BrowserWakeStandIn) {
        guard let shown else { return }
        remove()
        let pixels = shown.view.decodedPicture
        page.showStandIn(pixels ?? shown.picture, decoded: pixels != nil || shown.decoded, cap: shown.cap, clock: shown.clock)
    }

    public func remove() {
        guard let gone = shown else { return }
        shown = nil
        gone.timer.cancel()
        gone.view.removeFromSuperview()
    }
}
