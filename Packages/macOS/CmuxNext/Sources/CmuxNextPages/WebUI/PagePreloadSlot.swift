public import AppKit
public import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace
package import CmuxNextWakeups
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
/// - Refit: a new target size only records the size and arms one quiet deadline (``refitQuiet``);
///   each later refit pushes it back. Once the size has been still that long, a parked page thaws,
///   lays out at the size once and parks again after it painted there. A resize drag of the target
///   pane costs one thaw, layout, cover and freeze, not one per step (Chrome resizes a hidden
///   WebContents only when it is shown again: content/browser/renderer_host/render_widget_host_impl.cc
///   `WasShown`).
/// - Claim: in the key's turn the cover goes on top of the page (only when the page parked at the
///   claim's size: a cover of another size would show stretched), the page thaws, moves into the tab
///   at its frame and shows (thaw before visible); the cover goes in the turn of the page's first
///   live frame, or at ``coverLimit`` when no frame comes (a renderer that died while parked).
///   Nothing animates: every layer change runs with actions disabled.
/// - Drop: any non-normal memory pressure (``memoryPressureDidChange(_:)``, through
///   ``WebUIHost``'s memory coordinator registration) closes the page, and no preload starts until normal.
///
/// Which page to preload and when (first paint or 3 s, then 750 ms of quiet input) is the pure
/// `PreloadSelector`'s choice; the slot only holds what it is given.
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
        /// Thawed and shown in the parking at a new size after the refit's quiet deadline, until it
        /// painted there.
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
        /// Its cover is on top until its first live frame (false: it was claimed before it parked,
        /// or it was laid out at another size than its frame).
        public let covered: Bool
        /// It was laid out at another size than its frame: the claim resized it.
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
        /// The size the page is laid out at, which its cover shows.
        var size: NSSize
        /// The size it will show at; differs from `size` until the refit's quiet deadline.
        var target: NSSize
        var phase: Phase
        var cover: CGImage?
        /// The engine took the freeze (``PreloadablePage/preloadFreeze()`` returned true).
        var frozen = false
    }

    /// How long the target size must stay still before a refit lays the page out and parks it
    /// again: the 750 ms of quiet input the preload selector waits for.
    public static let refitQuiet: Duration = .milliseconds(750)
    /// The longest a claimed cover stays up when the page shows no live frame: past D4's cold open
    /// (150 ms p95), so a slow first frame keeps its cover and a dead renderer does not leave a
    /// stale picture on top of the tab.
    public static let coverLimit: Duration = .milliseconds(500)

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
    /// Told the key of the page that left after a claim or a drop emptied the slot (``observeEmptied(_:)``).
    private var emptiedListeners: [@MainActor (Key) -> Void] = []
    /// Told the key of a page ``dropStale()`` dropped (``observeStaleDropped(_:)``).
    private var staleDroppedListeners: [@MainActor (Key) -> Void] = []
    private let trace: @MainActor (Move, UInt64) -> Void
    /// Where the refit's quiet deadline and each cover's limit go (the app's `mainDeadlines`).
    private let deadlines: MainDeadlineScheduler
    /// The refit's one quiet deadline: work on a page nobody sees, so the background class.
    private let settleDeadline: MainDeadline

    /// - Parameters:
    ///   - parkState: How a ready preload waits.
    ///   - deadlines: The app's deadline scheduler (`AppServices.mainDeadlines`).
    package convenience init(parkState: ParkState = .frozenHidden, deadlines: MainDeadlineScheduler) {
        self.init(parkState: parkState, deadlines: deadlines) { move, page in
            TraceRuntime.shared.event(.webuiPreload, arg0: page, arg1: move.rawValue)
        }
    }

    /// - Parameters:
    ///   - parkState: How a ready preload waits.
    ///   - deadlines: The deadline scheduler (a test passes one on a hand-fired queue).
    ///   - trace: Where the `webui.preload` moves go (a recorder in tests).
    init(parkState: ParkState, deadlines: MainDeadlineScheduler, trace: @escaping @MainActor (Move, UInt64) -> Void) {
        self.parkState = parkState
        self.deadlines = deadlines
        self.trace = trace
        settleDeadline = MainDeadline(owner: "webui.preload.refit", workClass: .background, scheduler: deadlines)
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
    /// Whether the held page is frozen: false when the engine refused the freeze (it waits hidden).
    public var isFrozen: Bool { held?.frozen ?? false }
    /// The size the held page will show at; nil while the slot is empty.
    public var targetSize: NSSize? { held?.target }
    /// Whether a preload may start now: memory pressure is normal.
    public var allowsPreload: Bool { pressure == .normal }

    /// Calls `listener` with the key of the page that left each time a claim or a drop empties the
    /// slot, after the listeners added before it. Each preload owner arms its next page there: New
    /// Tab when another page left, Settings, History and Cloud (`PagePreloads`)
    /// whenever, as Chrome's preload manager preloads again once its contents are taken
    /// (webui_contents_preload_manager.cc, `Request`). Owners preload only into an empty slot, so
    /// the first to fill it keeps it (no owner evicts another's page).
    public func observeEmptied(_ listener: @escaping @MainActor (Key) -> Void) {
        emptiedListeners.append(listener)
    }

    private func emptied(_ key: Key) {
        for listener in emptiedListeners { listener(key) }
    }

    /// Calls `listener` with the key of the page each time ``dropStale()`` dropped it, after the
    /// ``observeEmptied(_:)`` listeners: its owner makes it again, from the web files served now (an
    /// owner that does not arm its own page on a plain drop, as New Tab, arms it here).
    public func observeStaleDropped(_ listener: @escaping @MainActor (Key) -> Void) {
        staleDroppedListeners.append(listener)
    }

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
        held = Held(key: key, page: page, parking: parking, size: size, target: size, phase: .loading)
        Self.withoutActions { parking.hold(page.preloadView, at: size) }
        page.preloadSetVisible(true)
        awaitPaint()
        return true
    }

    /// The held page will show at `size` now (the target pane changed size or focus). The page is
    /// not touched in this turn: once the size has been still for ``refitQuiet``, a parked page
    /// thaws, lays out at `size` in the parking and parks again after it painted there. A refit
    /// back to the size the page is laid out at cancels the pending one.
    public func refit(to size: NSSize) {
        guard var held, held.target != size else { return }
        held.target = size
        self.held = held
        guard held.size != size else {
            settleDeadline.cancel()
            return
        }
        settleDeadline.schedule(after: Self.refitQuiet) { [weak self] in self?.settle() }
    }

    /// Hands the held page to the open of `key` in this turn: its cover on top, thawed, moved into
    /// `container` at `frame`, and visible. The slot is empty after.
    ///
    /// - Parameters:
    ///   - key: The page the open shows.
    ///   - container: The tab content that shows it.
    ///   - frame: Its frame in `container`.
    ///   - covers: False when the opener does not know the size the page will show at yet (a new
    ///     workspace's first pane): a cover of the parked size would show stretched there.
    /// - Returns: The claim, or nil when the slot holds no page of `key` (the open builds one).
    public func claim(_ key: Key, into container: NSView, frame: NSRect, cover covers: Bool = true) -> Claim? {
        guard let held, held.key == key else { return nil }
        let start = ContinuousClock.now
        self.held = nil
        generation &+= 1
        settleDeadline.cancel()
        let page = held.page, view = page.preloadView
        let refit = held.size != frame.size
        var cover: PagePreloadCoverView?
        Self.withoutActions {
            // In the page view, on top: it moves with the page and goes with it if the page closes
            // first. Only at the size it was taken at: autoresized to another frame it would stretch.
            if covers, held.phase == .parked, !refit, let image = held.cover {
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
            // Off at the first live frame, or at the limit when none comes (a renderer that died parked).
            let limit = MainDeadline(owner: "webui.preload.cover", workClass: .visible, scheduler: deadlines)
            cover.limit = limit
            limit.schedule(after: Self.coverLimit) { [weak cover] in cover?.remove() }
            page.preloadWhenPainted { [weak cover] in cover?.remove() }
        }
        trace(.claim, page.preloadTraceID)
        let milliseconds = Self.milliseconds(since: start)
        lastClaim = ClaimRecord(key: key, covered: cover != nil, refit: refit, milliseconds: milliseconds)
        emptied(key)
        return Claim(page: page, covered: cover != nil, refit: refit, milliseconds: milliseconds)
    }

    /// Closes the held page, if any.
    public func drop() {
        guard let held else { return }
        self.held = nil
        generation &+= 1
        settleDeadline.cancel()
        trace(.drop, held.page.preloadTraceID)
        held.page.preloadView.removeFromSuperview()
        held.page.close()
        emptied(held.key)
    }

    /// The served web files changed (``WebUIHost/webBundleDidChange()``): the held page, loaded from
    /// the old files, is dropped, and its owner makes it again (``observeStaleDropped(_:)``).
    public func dropStale() {
        guard let key else { return }
        drop()
        for listener in staleDroppedListeners { listener(key) }
    }

    /// The memory pressure changed (``WebUIHost``'s memory registration): anything but normal drops
    /// the held page, and no preload starts until normal again (Chrome makes no preload under
    /// heavy pressure).
    public func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        pressure = level
        if level != .normal { drop() }
    }

    // MARK: Park

    /// The refit's quiet deadline: lays the page out at its target size once and parks it again
    /// there. A page still loading goes on loading at the new size; a cover being taken at the old
    /// size is dropped (the generation moves on) and taken again.
    private func settle() {
        guard var held, held.target != held.size else { return }
        held.size = held.target
        held.cover = nil
        switch held.phase {
        case .parked:
            if held.frozen { held.page.preloadThaw() }
            held.frozen = false
            held.page.preloadSetVisible(true)
            held.phase = .refitting
        case .capturing:
            held.phase = .refitting
        case .loading, .refitting:
            break
        }
        generation &+= 1
        self.held = held
        Self.withoutActions { held.parking.hold(held.page.preloadView, at: held.size) }
        awaitPaint()
    }

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
            // A refused freeze (a fork before SetPageFrozen) leaves it hidden and running.
            held.frozen = held.page.preloadFreeze()
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
