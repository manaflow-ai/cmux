public import AppKit
public import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace
import QuartzCore

/// The app's one preloaded page document (plans/cmux-next/chrome-parity/p13-webui.md 3.D): at most
/// one page loads ahead, out of sight, and the next open of that page takes it in the open's turn.
///
/// Chrome keeps the same rule for its WebUI (chrome/browser/ui/webui/top_chrome/
/// webui_contents_preload_manager.h: "At anytime, at most one WebContents is preloaded across all
/// profiles"): the preload is made visible so its resources load at once and is hidden when it is
/// ready (`kPreloadTopChromeWebUIHideWhenReady`), and no preload is kept under memory pressure. Here:
///
/// - Park: the page loads visible in a ``PreloadParking`` at the size it will show at, waits for its
///   load and first paint, keeps that frame as its cover, then hides; with ``ParkState/frozenHidden``
///   it also freezes (hidden before freeze).
/// - Refit: a new target size while parked thaws, lays the page out at the new size and parks again
///   once it painted there (the old cover is dropped: it shows the old size).
/// - Claim: in the key's turn the cover goes on top of the page, the page thaws, moves into the tab
///   at its frame and shows (thaw before visible); the cover goes in the turn of the page's first
///   live frame. Nothing animates: every layer change runs with actions disabled.
/// - Drop: any non-normal memory pressure (``memoryPressureDidChange(_:)``, through
///   ``WebUIHost``'s one subscription) closes the page, and no preload starts until normal.
///
/// Which page to preload and when (first paint or 3 s, then 750 ms of quiet input) is the pure
/// `PreloadSelector`'s choice (p13-webui-042); the slot only holds what it is given.
///
/// ```swift
/// webUI.preload.preload(.init("newTab"), size: paneSize, in: parking) { size in makeNewTab(size) }
/// if let claim = webUI.preload.claim(.init("newTab"), into: paneContent, frame: paneContent.bounds) { adopt(claim.page) }
/// ```
@MainActor
public final class PagePreloadSlot {
    /// How a ready preload waits (spike 090 measures both; p13-webui.md 3.D).
    public enum ParkState: String, Sendable {
        /// Hidden, then frozen: no task, timer or frame runs until the claim thaws it.
        case frozenHidden
        /// Hidden only: JS runs as the engine runs a hidden page (`visibilityState == "hidden"`).
        case renderedParked
    }

    /// Where the held page is.
    public enum Phase: String, Sendable {
        /// Loading visible in the parking, until its load and first paint.
        case loading
        /// Painted; its cover is being taken.
        case capturing
        /// Hidden (and frozen with ``ParkState/frozenHidden``), with its cover.
        case parked
        /// Thawed and shown in the parking at a new size, until it painted there.
        case refitting
    }

    /// Which page a preload is: the open that may claim it asks for the same key.
    public struct Key: Hashable, Sendable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    /// One claim, as the opener gets it.
    public struct Claim {
        /// The page, now in the claiming container at its frame and visible.
        public let page: any PreloadablePage
        /// Its cover is on top until its first live frame (false: it was claimed before it parked).
        public let covered: Bool
        /// It waited at another size than its frame: the claim resized it.
        public let refit: Bool
        /// Main-thread time of the claim.
        public let milliseconds: Double
    }

    /// One claim, for `debug.webui` and benches (no page reference, so it keeps nothing alive).
    public struct ClaimRecord: Sendable {
        public let key: Key
        public let covered: Bool
        public let refit: Bool
        public let milliseconds: Double
    }

    /// A move on the `webui.preload` track (arg1).
    enum Move: UInt64 {
        case park = 0
        case claim = 1
        case drop = 2
    }

    private struct Held {
        let key: Key
        let page: any PreloadablePage
        var parking: any PreloadParking
        var size: NSSize
        var phase: Phase
        var cover: CGImage?
        var frozen = false
    }

    /// How a ready preload waits. Spike 090 (bench-webui.py) has not written its result yet; the
    /// composition root passes the park state it chooses.
    public let parkState: ParkState
    private var held: Held?
    /// Moves on with every change of the held page, so a callback from an earlier phase or page
    /// does nothing.
    private var generation: UInt64 = 0
    /// The last memory pressure level the host passed on.
    public private(set) var pressure: MemoryPressureLevel = .normal
    /// The last claim (`debug.webui`).
    public private(set) var lastClaim: ClaimRecord?
    private let trace: @MainActor (Move, UInt64) -> Void

    /// - Parameter parkState: How a ready preload waits.
    public convenience init(parkState: ParkState = .frozenHidden) {
        self.init(parkState: parkState) { move, page in
            TraceRuntime.shared.event(.webuiPreload, arg0: page, arg1: move.rawValue)
        }
    }

    /// - Parameters:
    ///   - parkState: How a ready preload waits.
    ///   - trace: Where the `webui.preload` moves go (a recorder in tests).
    init(parkState: ParkState, trace: @escaping @MainActor (Move, UInt64) -> Void) {
        self.parkState = parkState
        self.trace = trace
    }

    // MARK: Reading

    /// The held page's key; nil while the slot is empty.
    public var key: Key? { held?.key }
    /// The held page's phase; nil while the slot is empty.
    public var phase: Phase? { held?.phase }
    /// The number of held pages: 0 or 1.
    public var count: Int { held == nil ? 0 : 1 }
    /// The held page, left in the slot (`debug.webui`).
    public var page: (any PreloadablePage)? { held?.page }
    /// Whether a preload may start now: memory pressure is normal.
    public var allowsPreload: Bool { pressure == .normal }

    // MARK: Moves

    /// Starts preloading `key` at `size` in `parking`, unless it is held already: then it moves to
    /// `parking` (a reparent, no reload: the key window changed) and follows `size`. Another held
    /// page is closed first, so at most one page is ever held.
    ///
    /// - Parameters:
    ///   - key: The page.
    ///   - size: The size it will show at (the target pane's content).
    ///   - parking: Where it waits, in a window.
    ///   - make: Builds the page at `size`; nil: no preload.
    /// - Returns: Whether `key` is held now.
    @discardableResult
    public func preload(_ key: Key, size: NSSize, in parking: any PreloadParking,
                        make: (NSSize) -> (any PreloadablePage)?) -> Bool {
        guard allowsPreload else { return false }
        if var held, held.key == key {
            if held.parking !== parking {
                held.parking = parking
                self.held = held
                Self.withoutActions { parking.hold(held.page.preloadView, at: held.size) }
            }
            refit(to: size)
            return true
        }
        drop()
        guard let page = make(size) else { return false }
        generation &+= 1
        held = Held(key: key, page: page, parking: parking, size: size, phase: .loading)
        Self.withoutActions { parking.hold(page.preloadView, at: size) }
        page.preloadSetVisible(true)
        awaitPaint()
        return true
    }

    /// The held page will show at `size` now (the target pane changed size or focus). A parked
    /// page thaws, shows in the parking at `size` and parks again once it painted there.
    public func refit(to size: NSSize) {
        guard var held, held.size != size else { return }
        held.size = size
        held.cover = nil
        if held.phase == .parked {
            if held.frozen { held.page.preloadThaw() }
            held.frozen = false
            held.page.preloadSetVisible(true)
        }
        if held.phase != .loading { held.phase = .refitting }
        generation &+= 1
        self.held = held
        Self.withoutActions { held.parking.hold(held.page.preloadView, at: size) }
        awaitPaint()
    }

    /// Hands the held page to the open of `key` in this turn: its cover on top, thawed, moved into
    /// `container` at `frame`, and visible. The slot is empty after.
    ///
    /// - Parameters:
    ///   - key: The page the open shows.
    ///   - container: The tab content that shows it.
    ///   - frame: Its frame in `container`.
    /// - Returns: The claim, or nil when the slot holds no page of `key` (the open builds one).
    public func claim(_ key: Key, into container: NSView, frame: NSRect) -> Claim? {
        guard let held, held.key == key else { return nil }
        let start = ContinuousClock.now
        self.held = nil
        generation &+= 1
        let page = held.page, view = page.preloadView
        let refit = held.size != frame.size
        var cover: PagePreloadCoverView?
        Self.withoutActions {
            // In the page view, on top: it moves with the page and goes with it if the page closes first.
            if held.phase == .parked, let image = held.cover {
                let made = PagePreloadCoverView(image: image, frame: view.bounds)
                view.addSubview(made, positioned: .above, relativeTo: nil)
                cover = made
            }
            if held.frozen { page.preloadThaw() }
            view.frame = frame
            container.addSubview(view)
        }
        page.preloadSetVisible(true)
        if let cover {
            page.preloadWhenPainted { [weak cover] in cover?.remove() }
        }
        trace(.claim, page.preloadTraceID)
        let milliseconds = Self.milliseconds(since: start)
        lastClaim = ClaimRecord(key: key, covered: cover != nil, refit: refit, milliseconds: milliseconds)
        return Claim(page: page, covered: cover != nil, refit: refit, milliseconds: milliseconds)
    }

    /// Closes the held page, if any.
    public func drop() {
        guard let held else { return }
        self.held = nil
        generation &+= 1
        trace(.drop, held.page.preloadTraceID)
        held.page.preloadView.removeFromSuperview()
        held.page.close()
    }

    /// The memory pressure changed (``WebUIHost``'s one subscription): anything but normal drops
    /// the held page, and no preload starts until normal again (Chrome makes no preload under
    /// heavy pressure).
    public func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        pressure = level
        if level != .normal { drop() }
    }

    // MARK: Park

    /// Takes the cover at the held page's next paint, then parks it.
    private func awaitPaint() {
        guard let held else { return }
        let generation = generation
        held.page.preloadWhenPainted { [weak self] in
            guard let self, self.generation == generation else { return }
            self.capture()
        }
    }

    private func capture() {
        guard var held else { return }
        held.phase = .capturing
        self.held = held
        let generation = generation
        held.page.preloadCaptureCover { [weak self] image in
            guard let self, self.generation == generation else { return }
            self.park(cover: image)
        }
    }

    /// Hides the held page (and freezes it with ``ParkState/frozenHidden``), keeping `cover`.
    private func park(cover: CGImage?) {
        guard var held, held.phase == .capturing else { return }
        held.cover = cover
        held.page.preloadSetVisible(false)
        if parkState == .frozenHidden {
            held.page.preloadFreeze()
            held.frozen = true
        }
        held.phase = .parked
        self.held = held
        trace(.park, held.page.preloadTraceID)
    }

    /// Runs `body`'s layer changes with implicit actions off (p13-webui.md 4.4).
    static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

/// A claimed page's cover: the frame it painted while parked, on top of the page until its first
/// live frame. Its layer never animates (p13-webui.md 4.4: layers this area adds run with actions
/// disabled), and it is out of the mouse's and accessibility's way.
final class PagePreloadCoverView: NSView {
    /// The layer actions the cover turns off (a nil action for each, besides the view's own).
    static let quietKeys = ["contents", "bounds", "position", "opacity", "hidden", "onOrderIn", "onOrderOut",
                            "sublayers", "transform", "contentsScale"]

    private let image: CGImage

    init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        if let layer {
            var actions: [String: any CAAction] = [:]
            for key in Self.quietKeys { actions[key] = NSNull() }
            layer.actions = actions
            layer.contentsGravity = .resize
            // Now, so the picture is in the claim's frame; `updateLayer` sets it again on a redisplay.
            layer.contents = image
        }
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Takes the cover off, with no animation.
    func remove() {
        PagePreloadSlot.withoutActions { removeFromSuperview() }
    }
}
