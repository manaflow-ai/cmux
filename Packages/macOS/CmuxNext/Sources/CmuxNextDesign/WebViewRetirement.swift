import CmuxNextWakeups
import ObjectiveC
public import WebKit

/// Ends the WKWebView of a closed page (a browser tab, an agent page, a page host) the one way
/// macOS 26's WebKit survives: out of its window first, its page closed only after its scrolling
/// stopped, its last reference dropped on a turn of ours.
///
/// The bug (nightly crash 2026-10-25, Cmd-W held over many tabs; bugs.webkit.org 315775, fixed
/// upstream in 314099@main after macOS 26.6): while a page scrolls (a wheel event in the last
/// 500 ms, momentum, a smooth-scroll animation) its scroll event dispatcher watches the display
/// link. Closing the page frees its scrolling coordinator without invalidating it, and the
/// coordinator's destructor asks the dispatcher to stop watching through the coordinator it is
/// destroying, so the lookup fails: the freed watcher stays registered and the display-link thread
/// calls into zeroed memory on the next refresh (`DisplayLink::notifyObserversDisplayDidRefresh`,
/// SIGSEGV at 0x10).
///
/// So a retired view leaves its window at once (no input reaches it), stays alive for
/// ``quietPeriod`` (WebKit's wheel hysteresis, momentum and scroll animations end and stop
/// watching through the living coordinator), then its page closes (`-[WKWebView _close]`, what
/// Safari does for a closed tab) while the retirement holds it, and the retirement drops it on its
/// own turn rather than inside a WebKit callback that happened to hold it last. A retirement keeps
/// itself alive through its pending deadline: the owner does not hold it.
///
/// ```swift
/// webView.stopLoading()
/// WebViewRetirement.retire(webView) // from the owner's close()
/// ```
@MainActor
public final class WebViewRetirement {
    /// How long a retired view stays alive out of its window before its page closes: past WebKit's
    /// 500 ms wheel hysteresis and the end of a momentum fling or a smooth-scroll animation.
    public static let quietPeriod: Duration = .seconds(3)

    private var webView: WKWebView?
    private let timer: DemandTimer
    private let closePage: @MainActor (WKWebView) -> Void

    /// Takes `webView` out of its window now and closes its page after `quietPeriod`. The owner has
    /// already stopped it and dropped its delegates and handlers.
    /// - Parameters:
    ///   - clock: The clock of the wait (tests inject one).
    ///   - closePage: Closes the view's page (tests observe it).
    public init(_ webView: WKWebView,
                quietPeriod: Duration = WebViewRetirement.quietPeriod,
                clock: any Clock<Duration> = ContinuousClock(),
                closePage: @escaping @MainActor (WKWebView) -> Void = WebViewRetirement.closePage) {
        self.webView = webView
        self.timer = DemandTimer(owner: "WebViewRetirement", clock: clock)
        self.closePage = closePage
        webView.removeFromSuperview()
        // The deadline holds this retirement, and through it the view, until the page closed.
        timer.schedule(after: quietPeriod) { @MainActor [self] in finish() }
    }

    /// Retires `webView` (see the type); the retirement needs no owner.
    @discardableResult
    public static func retire(_ webView: WKWebView) -> WebViewRetirement {
        WebViewRetirement(webView)
    }

    /// True once the view's page closed and the retirement let the view go.
    public var isFinished: Bool { webView == nil }

    /// Closes the page now (app quit, memory pressure, tests); nothing when it already closed.
    public func finish() {
        timer.cancel()
        guard let webView else { return }
        self.webView = nil
        closePage(webView)
        // `webView` goes at the end of this turn: ours, not a WebKit callback's.
    }

    /// Closes the page of `webView` (`-[WKWebView _close]`; nothing when this WebKit has no such SPI,
    /// the view's release then closes it).
    public static func closePage(_ webView: WKWebView) {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_close")
        guard webView.responds(to: selector) else { return }
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        webView.perform(selector)
    }

    /// Whether the page of `webView` is closed (`-[WKWebView _isClosed]`); nil when this WebKit has
    /// no such SPI.
    public static func isPageClosed(_ webView: WKWebView) -> Bool? {
        let selector = NSSelectorFromString("_isClosed")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return nil }
        typealias IsClosed = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: IsClosed.self)(webView, selector)
    }
}
