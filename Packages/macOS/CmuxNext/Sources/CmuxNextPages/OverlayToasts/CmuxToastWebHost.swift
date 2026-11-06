public import AppKit
public import CmuxNextDesign

/// Draws each window's toasts as the overlay page's React toast stack (`cmux-page://cmux.overlay/`,
/// route `/toasts`, webviews/src/pages/overlay/toasts) on the window's `WindowOverlayHost` (`.toast`).
///
/// One pre-warmed transparent page per window (``OverlayPage``), so a toast showing is a state push,
/// never a page load. The page covers the window's content inset by the overlay's 8 pt margin and
/// draws the stack bottom-center; it reports where its toasts are (``CmuxToastPageProvider/Report``),
/// and the overlay takes clicks only there, so the rest of the window stays usable. The page stays
/// presented while toasts show or fade, and leaves the overlay once its last toast faded.
///
/// Toasts never cover the chat (#36969): the stack rests above every avoided view
/// (``CmuxToastAvoiding``, `floor` in the page's state), and the views that reserve room
/// (``CmuxToastReserving``) hear where the toasts rest whenever that changes.
@MainActor
public final class CmuxToastWebHost: CmuxToastHosting, CmuxToastReanchoring {
    /// The overlay page's route for the toast stack.
    public static let route = "/toasts"

    /// One window's stack.
    private final class Stack {
        weak var window: NSWindow?
        weak var center: CmuxToastCenter?
        let page: PageWebView
        let provider: CmuxToastPageProvider
        var handle: OverlayHandle?
        var shown: [CmuxToastShown] = []
        /// Where the toasts rest and where fading ones still draw (window coordinates), as the page last said.
        var rects: [NSRect] = []
        var fading: [NSRect] = []
        /// The union last told to the views that reserve room.
        var settled: NSRect?

        init(window: NSWindow, page: PageWebView, provider: CmuxToastPageProvider) {
            self.window = window
            self.page = page
            self.provider = provider
        }
    }

    private var stacks: [ObjectIdentifier: Stack] = [:]
    /// Makes (or finds) the window's pre-warmed page for `route` with its provider.
    private let page: @MainActor (_ route: String, _ window: NSWindow, _ provider: any PageProvider) -> PageWebView

    /// The overlay's margin around the page (``WindowOverlayHost`` clamps every overlay 8 pt inside the window).
    static let inset: CGFloat = 8
    /// The stack's bottom edge rests this far above the window's bottom (the native toast lift).
    static let lift: CGFloat = 24
    /// The width the stack is taken to have when it looks for the views it avoids, before the page
    /// reports its toasts (the widest a toast gets).
    static let assumedWidth: CGFloat = 420

    public init(page: @escaping @MainActor (_ route: String, _ window: NSWindow, _ provider: any PageProvider) -> PageWebView
        = { route, window, provider in OverlayPage.page(route: route, in: window, provider: provider) }) {
        self.page = page
    }

    // MARK: CmuxToastHosting

    public func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        let key = ObjectIdentifier(window)
        let stack: Stack
        if let existing = stacks[key], existing.window === window {
            stack = existing
        } else {
            guard !toasts.isEmpty else { return }
            // Stacks of windows that are gone go with them.
            stacks = stacks.filter { $0.value.window != nil }
            let provider = CmuxToastPageProvider { [weak self, weak window] report in
                guard let self, let window else { return }
                self.received(report, in: window)
            }
            stack = Stack(window: window, page: page(Self.route, window, provider), provider: provider)
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
        stack.page.setFrameSize(Self.pageSize(in: bounds))
        let options = OverlayOptions(kind: .toast, anchor: bounds, passesThroughClicks: false)
        let handle = WindowOverlayHost.host(for: window).present(stack.page, options: options)
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
            stack.page.setFrameSize(Self.pageSize(in: bounds))
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
        let pageBottom = bounds.minY + Self.inset
        return Double(max(0, lowest - pageBottom)) / max(stack.page.pageZoom, 0.01)
    }

    // MARK: The page's reports

    private func received(_ report: CmuxToastPageProvider.Report, in window: NSWindow) {
        guard let stack = stacks[ObjectIdentifier(window)] else { return }
        switch report {
        case .action(let serial):
            stack.center?.personRanAction(serial: serial)
        case .close(let serial):
            stack.center?.personClosed(serial: serial)
        case .hover(let serial, let hovered):
            stack.center?.pointer(onToast: serial, hovered)
        case .layout(let rects, let fading):
            // Rects of toasts the center no longer shows take no clicks.
            let live = Set(stack.shown.map(\.serial))
            stack.rects = rects.filter { live.contains($0.serial) }.map { windowRect($0, of: stack.page) }
            stack.fading = (fading + rects.filter { !live.contains($0.serial) }).map { windowRect($0, of: stack.page) }
            stack.handle?.update(hitRegions: stack.rects)
            settled(stack, in: window, duration: Self.moveDuration)
            // The last toast faded: the page leaves the overlay (it stays warm for the next toast).
            if stack.shown.isEmpty, stack.rects.isEmpty, stack.fading.isEmpty { retire(stack, in: window) }
        }
    }

    /// A CSS-px rect of the page (from its top left) in window coordinates.
    private func windowRect(_ rect: CmuxToastPageProvider.Rect, of page: PageWebView) -> NSRect {
        let zoom = CGFloat(max(page.pageZoom, 0.01))
        let height = CGFloat(rect.h) * zoom
        let top = CGFloat(rect.y) * zoom
        let local = NSRect(x: CGFloat(rect.x) * zoom, y: page.isFlipped ? top : page.bounds.height - top - height,
                           width: CGFloat(rect.w) * zoom, height: height)
        return page.window == nil ? local : page.convert(local, to: nil)
    }

    private func retire(_ stack: Stack, in window: NSWindow) {
        guard let handle = stack.handle else { return }
        stack.handle = nil
        handle.onDismiss = nil
        handle.onWindowGeometryChange = nil
        handle.dismiss()
        CmuxToastAvoidance.unregister(self, from: window)
    }

    private func forget(_ window: NSWindow) {
        CmuxToastAvoidance.unregister(self, from: window)
        stacks[ObjectIdentifier(window)] = nil
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
