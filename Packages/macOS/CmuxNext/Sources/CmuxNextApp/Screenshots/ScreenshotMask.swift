import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextHome
import CmuxNextPages
import CmuxNextWakeups
import WebKit

/// What an agent's or a script's capture of a window (`cmux window|pane|tab screenshot` over the
/// control socket) covers: every browser page area, every chat and conversation, and every app
/// page not known to show nothing secret. A page's pixels reach automation only through the
/// browser host's guarded capture (`cmux browser page screenshot`, which hides the secrets
/// sessions typed), and a chat's text only through `cmux agents chat read`, which masks
/// secrets; a window capture masks them whole. App pages are masked unless listed in
/// ``shownAppPages``, so a new page is masked until someone checks it.
///
/// The areas come from the window's view tree, not from what a pane's model says it shows, so a
/// page a pane keeps on screen while its next tab paints (`PanePaintHold`), a sleeping page's
/// picture and a page outside any chrome view are covered too. The screen lags the view tree by
/// a frame or two, so a ``Sampler`` reads the areas after every main run loop turn from
/// ``settle`` before the capture until after it, and the mask is every area any reading saw.
@MainActor
struct ScreenshotMask {
    /// The areas to cover, in window coordinates.
    var regions: [NSRect] = []
    /// False when an area or a view holding it was animating (its pixels are not where its frame
    /// says) or the window changed size between readings.
    var isSettled = true

    /// How long the areas are read before the capture: longer than the window server takes to
    /// show a committed frame.
    static let settle: Duration = .milliseconds(100)
    /// Captures tried while the window keeps animating, before the run fails.
    static let attempts = 3

    /// Waits ``settle`` on a one-shot deadline.
    static func waitToSettle() async {
        let timer = DemandTimer(owner: "screenshot.mask-settle")
        await withExtendedLifetime(timer) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                timer.schedule(after: settle) { done.resume() }
            }
        }
    }

    /// Why a masked capture gave no image.
    enum Failure: Error {
        /// The window kept animating or resizing through every attempt.
        case unsettled
        /// The masks could not be painted.
        case unmaskable
    }

    /// The areas `window` shows now.
    static func read(_ window: NSWindow) -> ScreenshotMask {
        var mask = ScreenshotMask()
        guard let root = window.contentView?.superview ?? window.contentView else { return mask }
        func add(_ view: NSView) {
            let rect = view.convert(view.bounds, to: nil)
            if rect.width > 0, rect.height > 0, !mask.regions.contains(rect) { mask.regions.append(rect) }
            if isMoving(view) || view.superview.map({ sequence(first: $0, next: \.superview).contains(where: movesChildren) }) == true {
                mask.isSettled = false
            }
        }
        func visit(_ view: NSView, inAppPage: Bool) {
            // Hidden takes effect at once; a transparent view may still be fading out.
            if view.isHidden || (view.alphaValue == 0 && !isMoving(view)) { return }
            if covers(view) || (view is WKWebView && !inAppPage) {
                add(view)
                return
            }
            if let chrome = view as? BrowserChromeView { add(chrome.pageArea) }
            // A chat's last frame, drawn under the pane's content until its page paints.
            if let launch = (view as? PaneContentView)?.launchImageView, !launch.isHidden { add(launch) }
            let inAppPage = inAppPage || view is PageWebView
            for child in view.subviews { visit(child, inAppPage: inAppPage) }
        }
        visit(root, inAppPage: false)
        return mask
    }

    /// The app pages a capture shows: they hold no secret, chat or browsing data, and nothing an
    /// agent cannot read another way (files, diffs, keys, the changelog). Every other app page
    /// (Settings with its key fields, Passwords, History, Home Channels, the agent page, Agent
    /// Activity's screen frames, the Chief's pages) is masked.
    static let shownAppPages: Set<String> = [
        "cmux.keybindings", "cmux.changelog", "cmux.icon-picker", "cmux.apps", "cmux.diff", "cmux.markdown", "cmux.editor",
        "cmux.files", "cmux.debug-settings",
    ]

    /// Whether a capture covers `view` whole: a browser tab's page, an agent chat, a Home
    /// conversation, list or draft, or an app page not in ``shownAppPages``. Any other web view is
    /// covered unless a shown app page holds it (``read(_:)``).
    static func covers(_ view: NSView) -> Bool {
        if let page = view as? PageWebView { return !shownAppPages.contains(page.descriptor.id) }
        return BrowserChromeView.isPageContent(view) || view is AgentPaneView || view is HomeHostView || view is TopHomePageView
            || view is HomeNewMessageView || view is HomeDockSwitchView || view is HomeSidebarView || view is HomeNativeTranscriptView
    }

    /// Whether `view` or a view holding it is covered: its own image is not painted in.
    static func isCovered(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0 is BrowserChromeView || covers($0) }
    }

    /// An animation or a layer transform puts the view's pixels somewhere other than its frame.
    private static func isMoving(_ view: NSView) -> Bool {
        guard let layer = view.layer else { return false }
        return layer.animationKeys()?.isEmpty == false || !CATransform3DIsIdentity(layer.transform)
    }

    /// The same for a view holding a covered one, whose sublayer transform moves it too.
    private static func movesChildren(_ view: NSView) -> Bool {
        isMoving(view) || view.layer.map { !CATransform3DIsIdentity($0.sublayerTransform) } == true
    }

    /// Reads a window's mask after every main run loop turn (once Core Animation has committed
    /// the turn's changes) until ``stop()``, keeping every area any reading saw. Its owner stops
    /// it on every path (`defer`): a running sampler reads the window each turn.
    @MainActor
    final class Sampler {
        private let window: NSWindow
        private let size: NSSize
        private(set) var mask = ScreenshotMask()
        private var observer: CFRunLoopObserver?

        init(window: NSWindow) {
            self.window = window
            size = window.frame.size
            sample()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sample() } // main-proof: the observer is added only to CFRunLoopGetMain() (below)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        /// One reading now.
        func sample() {
            let now = ScreenshotMask.read(window)
            for rect in now.regions where !mask.regions.contains(rect) { mask.regions.append(rect) }
            if !now.isSettled || window.frame.size != size { mask.isSettled = false }
        }

        /// Takes a last reading and stops; later calls do nothing.
        func stop() {
            guard let observer else { return }
            sample()
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
    }
}
