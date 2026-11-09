public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups

/// Draws each window's toasts as the overlay page's React toast stack (`cmux-page://cmux.overlay/`,
/// route `/toasts`, webviews/src/pages/overlay/toasts) on the window's `WindowOverlayHost` (`.toast`).
///
/// A window that shows toasts claims a warm page view from one pool shared by every window
/// (``OverlayPagePool``), so a toast showing is a state push, never a page load; the view goes back to
/// the pool once the window's last toast has faded. The page covers the window's content inset by the
/// overlay's 8 pt margin and draws the stack bottom-center; it reports where its toasts are
/// (``CmuxToastPageProvider/Report``), and the overlay takes clicks only there, so the rest of the
/// window stays usable.
///
/// Toasts never cover the chat (#36969): the stack rests above every avoided view
/// (``CmuxToastAvoiding``, `floor` in the page's state), and the views that reserve room
/// (``CmuxToastReserving``) hear where the toasts rest whenever that changes.
@MainActor
public final class CmuxToastWebHost: CmuxToastHosting, CmuxToastReanchoring {
    /// One window's stack.
    private final class Stack {
        weak var window: NSWindow?
        weak var center: CmuxToastCenter?
        let page: PageWebView
        /// What the overlay shows: the page, with the window's glass under each toast.
        let view: CmuxToastPageView
        let provider: CmuxToastPageProvider
        var handle: OverlayHandle?
        var shown: [CmuxToastShown] = []
        /// Where the toasts rest and where fading ones still draw (window coordinates), as the page last said.
        var rects: [NSRect] = []
        var fading: [NSRect] = []
        /// Each resting toast's rect (window coordinates), by serial, as the page last said.
        var placed: [Int: NSRect] = [:]
        /// The union last told to the views that reserve room.
        var settled: NSRect?
        /// Ends a move's wider click regions (each toast's old and new rect) once the move is done.
        let moveEnd = DemandTimer(owner: "CmuxToastWebHost.move")

        init(window: NSWindow, page: PageWebView, provider: CmuxToastPageProvider) {
            self.window = window
            self.page = page
            view = CmuxToastPageView(page: page)
            self.provider = provider
        }
    }

    private let pool: OverlayPagePool<CmuxToastPageProvider>

    /// The toasts' page pool. A first click in an inactive window presses a toast's button, as the
    /// native toast's buttons did (review of #37289 at 97fe7eab, F1), not only the window.
    static func makePool(overlayProcess: PageOverlayProcess? = nil) -> OverlayPagePool<CmuxToastPageProvider> {
        OverlayPagePool(route: "/toasts", acceptsFirstMouse: true, overlayProcess: overlayProcess) { CmuxToastPageProvider() }
    }
    private var stacks: [ObjectIdentifier: Stack] = [:]

    /// The overlay's margin around the page (``WindowOverlayHost`` clamps every overlay 8 pt inside the window).
    static let inset: CGFloat = 8
    /// The stack's bottom edge rests this far above the window's bottom (the native toast lift).
    static let lift: CGFloat = 24
    /// The width the stack is taken to have when it looks for the views it avoids, before the page
    /// reports its toasts (the widest a toast gets).
    static let assumedWidth: CGFloat = 420

    /// Draws `center`'s toasts from now on (the composition root makes one, for the shared center). Its pages
    /// run in `overlayProcess` (the app's one ``PageOverlayProcess``); nil gives each its own process.
    public init(drawing center: CmuxToastCenter, overlayProcess: PageOverlayProcess? = nil) {
        pool = Self.makePool(overlayProcess: overlayProcess)
        center.host = self
    }

    /// Loads the page of the next window's toasts ahead (an idle moment after launch).
    public func prewarm() {
        pool.prewarm()
    }

    // MARK: CmuxToastHosting

    public func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        let key = ObjectIdentifier(window)
        let stack: Stack
        if let existing = stacks[key], existing.window === window {
            stack = existing
        } else {
            guard !toasts.isEmpty, let (page, provider) = pool.claim() else { return }
            provider.onReport = { [weak self, weak window] report in
                guard let self, let window else { return }
                self.received(report, in: window)
            }
            stack = Stack(window: window, page: page, provider: provider)
            stacks[key] = stack
        }
        stack.center = center
        stack.shown = toasts
        if !toasts.isEmpty { present(stack, in: window) }
        publish(stack, in: window)
    }

    /// Puts the page on the window's overlay (once), sized to the window's content.
    private func present(_ stack: Stack, in window: NSWindow) {
        guard stack.handle == nil || stack.handle?.isDismissed == true else { return }
        let bounds = window.contentView?.bounds ?? .zero
        stack.view.setFrameSize(Self.pageSize(in: bounds))
        let options = OverlayOptions(kind: .toast, anchor: bounds, passesThroughClicks: false)
        let handle = WindowOverlayHost.host(for: window).present(stack.view, options: options)
        // No clicks until the page says where its toasts are.
        handle.update(hitRegions: stack.rects)
        handle.onDismiss = { [weak self, weak window, weak stack] in
            // The window closed: its toasts end with it.
            guard let self, let window, let stack else { return }
            stack.handle = nil
            if !stack.shown.isEmpty { stack.center?.windowClosed(window) }
            self.forget(window)
        }
        handle.onWindowGeometryChange = { [weak self, weak window, weak stack] in
            guard let self, let window, let stack, let handle = stack.handle else { return }
            let bounds = window.contentView?.bounds ?? .zero
            stack.view.setFrameSize(Self.pageSize(in: bounds))
            handle.update(anchor: bounds)
            self.publish(stack, in: window)
        }
        stack.handle = handle
        CmuxToastAvoidance.register(self, in: window)
    }

    /// The page's size in a content view of `bounds`: all of it but the overlay's margin.
    static func pageSize(in bounds: NSRect) -> NSSize {
        NSSize(width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - 2 * inset))
    }

    /// Sends the page the window's toasts and where the stack may rest.
    private func publish(_ stack: Stack, in window: NSWindow) {
        stack.provider.publish(CmuxToastPageProvider.state(stack.shown, floor: floor(of: stack, in: window)))
    }

    /// The stack's lowest bottom edge, in CSS px from the page's bottom: the lift above the window's
    /// bottom, or above the avoided views under the stack.
    private func floor(of stack: Stack, in window: NSWindow) -> Double {
        let bounds = window.contentView?.bounds ?? .zero
        let width = stack.rects.map(\.width).max() ?? Self.assumedWidth
        let lowest = max(bounds.minY + Self.lift, CmuxToastAvoidance.floor(width: width, in: bounds, window: window))
        // Where the overlay placed the page (review 1 of #37289): its bottom, not an assumed inset.
        let pageBottom = stack.page.window == nil ? bounds.minY + Self.inset : stack.page.convert(stack.page.bounds, to: nil).minY
        return Double(max(0, lowest - pageBottom)) / max(stack.page.pageZoom, 0.01)
    }

    // MARK: The page's reports

    private func received(_ report: CmuxToastPageProvider.Report, in window: NSWindow) {
        guard let stack = stacks[ObjectIdentifier(window)] else { return }
        // A press or hover counts only on a toast this window shows (a pooled page's late report does not).
        let shows = { (serial: Int) in stack.shown.contains { $0.serial == serial } }
        switch report {
        case .action(let serial):
            if shows(serial) { stack.center?.personRanAction(serial: serial) }
        case .close(let serial):
            if shows(serial) { stack.center?.personClosed(serial: serial) }
        case .hover(let serial, let hovered):
            if shows(serial) { stack.center?.pointer(onToast: serial, hovered) }
        case .layout(let rects, let fading):
            // Rects of toasts the center no longer shows take no clicks.
            let live = Set(stack.shown.map(\.serial))
            let resting = rects.filter { live.contains($0.serial) }
            let leaving = fading + rects.filter { !live.contains($0.serial) }
            let before = stack.placed
            stack.placed = Dictionary(resting.map { ($0.serial, windowRect($0, of: stack.page)) }) { first, _ in first }
            stack.rects = resting.map { windowRect($0, of: stack.page) }
            stack.fading = leaving.map { windowRect($0, of: stack.page) }
            stack.view.placeGlass(resting: resting.map { ($0.serial, localRect($0, of: stack.page)) },
                                  fading: leaving.map { ($0.serial, localRect($0, of: stack.page)) },
                                  zoom: CGFloat(stack.page.pageZoom))
            updateHitRegions(stack, movedFrom: before)
            settled(stack, in: window, duration: Self.moveDuration)
            // The last toast faded: the page leaves the overlay (it stays warm for the next toast).
            if stack.shown.isEmpty, stack.rects.isEmpty, stack.fading.isEmpty { retire(stack, in: window) }
        }
    }

    /// Where the toasts take clicks: while they slide to new places (the page and their glass move over
    /// ``moveDuration``), each takes them over its old and its new rect, so a click on a toast still on
    /// its way reaches it (review 4 of #37289); then only its new rect.
    private func updateHitRegions(_ stack: Stack, movedFrom before: [Int: NSRect]) {
        let moving = stack.placed.compactMap { serial, rect in before[serial].flatMap { $0 == rect ? nil : $0.union(rect) } }
        stack.moveEnd.cancel()
        stack.handle?.update(hitRegions: Self.moveDuration > 0 ? stack.rects + moving : stack.rects)
        guard !moving.isEmpty, Self.moveDuration > 0 else { return }
        stack.moveEnd.schedule(after: .seconds(Self.moveDuration)) { @MainActor [weak stack] in
            guard let stack else { return }
            stack.handle?.update(hitRegions: stack.rects)
        }
    }

    /// A CSS-px rect of the page (from its top left) in window coordinates.
    private func windowRect(_ rect: CmuxToastPageProvider.Rect, of page: PageWebView) -> NSRect {
        let local = localRect(rect, of: page)
        return page.window == nil ? local : page.convert(local, to: nil)
    }

    /// A CSS-px rect of the page (from its top left) in the page's own coordinates.
    private func localRect(_ rect: CmuxToastPageProvider.Rect, of page: PageWebView) -> NSRect {
        let zoom = CGFloat(max(page.pageZoom, 0.01))
        let height = CGFloat(rect.h) * zoom
        let top = CGFloat(rect.y) * zoom
        return NSRect(x: CGFloat(rect.x) * zoom, y: page.isFlipped ? top : page.bounds.height - top - height,
                      width: CGFloat(rect.w) * zoom, height: height)
    }

    /// The window's last toast faded: its page leaves the overlay and goes back to the pool.
    private func retire(_ stack: Stack, in window: NSWindow) {
        if let handle = stack.handle {
            stack.handle = nil
            handle.onDismiss = nil
            handle.onWindowGeometryChange = nil
            handle.dismiss()
        }
        forget(window)
    }

    /// Ends `window`'s stack: its page goes back to the pool (warm for the next window's toasts).
    private func forget(_ window: NSWindow) {
        CmuxToastAvoidance.unregister(self, from: window)
        guard let stack = stacks.removeValue(forKey: ObjectIdentifier(window)) else { return }
        stack.provider.onReport = nil
        stack.moveEnd.cancel()
        stack.provider.publish(CmuxToastPageProvider.state([], floor: 0))
        stack.view.releasePage()
        pool.release(stack.page)
        pool.prewarm()
    }

    // MARK: Reserving and avoiding

    /// How long the toasts take to reach their slots; the views under them move over the same time.
    private static var moveDuration: TimeInterval {
        Motion.overlays.animatesMovement ? Motion.overlays.duration(.move) : 0
    }

    /// The union of the window's toasts, fading ones included; nil when none shows.
    private static func union(of stack: Stack) -> NSRect? {
        let frames = stack.rects + stack.fading
        return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
    }

    /// Tells every view in `window` that reserves room for toasts where they rest now, when that changed.
    private func settled(_ stack: Stack, in window: NSWindow, duration: TimeInterval) {
        let rect = Self.union(of: stack)
        guard rect != stack.settled else { return }
        stack.settled = rect
        CmuxToastAvoidance.reservingViews(in: window).forEach { $0.toastsSettled(in: rect, duration: duration) }
    }

    /// An avoided view in `window` moved: the stack's floor follows (the page slides its toasts there).
    public func reanchor(in window: NSWindow) {
        guard let stack = stacks[ObjectIdentifier(window)] else { return }
        publish(stack, in: window)
    }

    public func settled(in window: NSWindow, only view: any CmuxToastReserving) {
        view.toastsSettled(in: stacks[ObjectIdentifier(window)].flatMap(Self.union), duration: 0)
    }
}
