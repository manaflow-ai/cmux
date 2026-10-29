public import AppKit
import CmuxNextWakeups
import WebKit

/// What an agent's or a script's capture of a window (`cmux window|pane|tab screenshot` over the
/// control socket) covers, read from the window's view tree. The app says which views those are
/// (``Rules``); this reads them, follows them while the capture runs and reports whether their
/// pixels were where their frames said.
///
/// The areas come from the view tree, not from what a pane's model says it shows, so a page a
/// pane keeps on screen while its next tab paints, a sleeping page's picture and a page outside
/// any chrome view are covered too. The screen lags the view tree by a frame or two, so a
/// ``Sampler`` reads the areas after every main run loop turn from ``settle`` before the capture
/// until after it, and the mask is every area any reading saw.
@MainActor
public struct ScreenshotMask {
    /// Which views a capture covers, by view type: the app owns the types, this package the
    /// geometry and the timing. Every rule is read on the main actor, with the view tree.
    @MainActor
    public struct Rules {
        /// Whether a capture covers `view` whole and does not look inside it.
        public let covers: @MainActor (NSView) -> Bool
        /// An area `view` contributes without covering `view` itself: a browser chrome's page
        /// area, a pane's chat launch image. Nil for none. A hidden view, or one inside a hidden
        /// view, contributes nothing to a reading: a ``Sampler``'s first reading comes
        /// ``settle`` before the capture, longer than the screen lags the view tree, so a view
        /// hidden before it is off the screen by then, and one hidden after it was in a reading.
        public let area: @MainActor (NSView) -> NSView?
        /// Whether `view` is one of the app's own pages. A web view inside one is the page's own
        /// content, so it is not covered for being a web view; any other web view is.
        public let isAppPage: @MainActor (NSView) -> Bool
        /// Whether `view` covers whatever sits inside it, so no view under it has its own image
        /// painted back in (``isCovered(_:rules:)``): a browser chrome, whose page area is a mask.
        public let coversContents: @MainActor (NSView) -> Bool

        public init(covers: @escaping @MainActor (NSView) -> Bool, area: @escaping @MainActor (NSView) -> NSView?,
                    isAppPage: @escaping @MainActor (NSView) -> Bool, coversContents: @escaping @MainActor (NSView) -> Bool) {
            self.covers = covers
            self.area = area
            self.isAppPage = isAppPage
            self.coversContents = coversContents
        }
    }

    /// The areas to cover, in window coordinates.
    public var regions: [NSRect] = []
    /// False when an area or a view holding it was animating (its pixels are not where its frame
    /// says), an area moved or resized between readings, or the window changed size between
    /// readings.
    public var isSettled = true
    /// Each area's frame in window coordinates, by its view, so a ``Sampler`` can tell an area
    /// that moved between readings (its pixels can sit between two readings' frames) from one
    /// that appeared or went away (the mask keeps every reading's, so either is covered).
    var frames: [ObjectIdentifier: NSRect] = [:]

    public init() {}

    /// How long the areas are read before the capture: longer than the window server takes to
    /// show a committed frame.
    public static let settle: Duration = .milliseconds(100)
    /// Captures tried while the window keeps animating, before the run fails.
    public static let attempts = 3

    /// Waits ``settle`` on a one-shot deadline.
    public static func waitToSettle() async {
        let timer = DemandTimer(owner: "screenshot.mask-settle")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.schedule(after: settle) { done.resume() }
        }
        // The timer cancels its deadline when it goes, which would never resume the wait.
        withExtendedLifetime(timer) {}
    }

    /// Why a masked capture gave no image.
    public enum Failure: Error {
        /// The window kept animating or resizing through every attempt.
        case unsettled
        /// The masks could not be painted.
        case unmaskable
    }

    /// The areas `window` shows now.
    public static func read(_ window: NSWindow, rules: Rules) -> ScreenshotMask {
        var mask = ScreenshotMask()
        guard let root = window.contentView?.superview ?? window.contentView else { return mask }
        func add(_ view: NSView) {
            let rect = view.convert(view.bounds, to: nil)
            if rect.width > 0, rect.height > 0, !mask.regions.contains(rect) { mask.regions.append(rect) }
            mask.frames[ObjectIdentifier(view)] = rect
            if isMoving(view) || view.superview.map({ sequence(first: $0, next: \.superview).contains(where: movesChildren) }) == true {
                mask.isSettled = false
            }
        }
        func visit(_ view: NSView, inAppPage: Bool) {
            // Hidden takes effect at once; a transparent view may still be fading out. A view
            // hidden during a capture was seen by an earlier reading (``Sampler``), and one hidden
            // before the first reading is off the screen by the capture, ``settle`` later.
            if view.isHidden || (view.alphaValue == 0 && !isMoving(view)) { return }
            if rules.covers(view) || (view is WKWebView && !inAppPage) {
                add(view)
                return
            }
            if let area = rules.area(view) { add(area) }
            let inAppPage = inAppPage || rules.isAppPage(view)
            for child in view.subviews { visit(child, inAppPage: inAppPage) }
        }
        visit(root, inAppPage: false)
        return mask
    }

    /// Whether `view` or a view holding it is covered: its own image is not painted in.
    public static func isCovered(_ view: NSView, rules: Rules) -> Bool {
        sequence(first: view, next: \.superview).contains { rules.coversContents($0) || rules.covers($0) }
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
    public final class Sampler {
        private let window: NSWindow
        private let rules: Rules
        private let size: NSSize
        public private(set) var mask = ScreenshotMask()
        private var observer: CFRunLoopObserver?
        /// The last reading's area frames (``ScreenshotMask/frames``).
        private var lastFrames: [ObjectIdentifier: NSRect] = [:]

        public init(window: NSWindow, rules: Rules) {
            self.window = window
            self.rules = rules
            size = window.frame.size
            sample()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sample() } // main-proof: the observer is added only to CFRunLoopGetMain() (below)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        /// One reading now.
        public func sample() {
            let now = ScreenshotMask.read(window, rules: rules)
            for rect in now.regions where !mask.regions.contains(rect) { mask.regions.append(rect) }
            if !now.isSettled || window.frame.size != size { mask.isSettled = false }
            // An area that moved or resized between two readings (a divider drag, a layout pass)
            // may have shown its pixels between the two frames, which no reading covers: refuse.
            for (view, rect) in now.frames where lastFrames[view].map({ $0 != rect }) == true { mask.isSettled = false }
            lastFrames = now.frames
        }

        /// Takes a last reading and stops; later calls do nothing.
        public func stop() {
            guard let observer else { return }
            sample()
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
    }
}
