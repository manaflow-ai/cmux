public import AppKit
import CoreFoundation
import ObjectiveC
import os

/// Catches a layout feedback loop before AppKit does.
///
/// AppKit throws `NSGenericException` ("needing another Layout Window pass,
/// but it has already had more Layout Window passes than there are views in
/// the window") when a view keeps marking the window for layout from inside
/// layout: a `layout()` that changes an ancestor's frame, sets
/// `needsLayout` on itself, or moves views between windows. The exception
/// names no view.
///
/// The guard counts `-[NSView layout]` calls per view in one run-loop turn
/// (an override that calls `super.layout()` counts; one that does not is
/// invisible). A normal turn lays out a view one to three times. When one
/// view passes its window's limit in one turn (``limit(viewCount:)``:
/// ``bound``, lower in a small window, because AppKit's own limit is the
/// window's view count and a fixed bound would never fire before a small
/// panel throws), the guard records a ``Report`` with
/// the view's class, its superview chain and its window class, logs a fault
/// and calls ``onLoop`` (the app sends it to Sentry as a non-fatal event).
/// One report per view class per launch. Reading: ``reports``,
/// ``passesByClass``, ``maxPassesInOneTurn`` (`debug.layers`).
///
/// With ``breaksLoops`` (release builds) the guard also ends the loop before
/// AppKit does: past ``breakLimit(viewCount:)``, the view's further
/// `-[NSView layout]` calls in that turn are skipped (an override's own code
/// around `super.layout()` still runs), and one layout is asked for
/// on the next turn, so the app keeps running. A view that merely lays out
/// often in a large window is never skipped, and the break count restarts
/// when the window changes frame: an animated resize (zoom) lays the window
/// out once per frame inside one turn. Debug builds leave it off, so a loop
/// still ends the app where it can be fixed.
@MainActor
public final class LayoutPassGuard {
    public struct Report: Sendable, Equatable {
        public var viewClass: String
        public var windowClass: String?
        /// Superview classes, nearest first (at most 8).
        public var ancestry: [String]
        /// Layout passes of the view in the turn when the limit was passed.
        public var passes: Int
        /// The window's limit then (``LayoutPassGuard/limit(viewCount:)``):
        /// below ``LayoutPassGuard/bound`` only in a small window.
        public var limit: Int
        public var at: Date
        /// The guard skips the view's layouts past its window's break limit
        /// (``breaksLoops``).
        public var broken = false
    }

    public static let shared = LayoutPassGuard()

    /// Layout calls of one view in one run-loop turn above which the turn
    /// is a loop. Well below AppKit's own limit (one pass per view in the
    /// window), well above a normal turn.
    public static let bound = 16

    /// A loop was found (main thread, once per view class per launch).
    public var onLoop: ((Report) -> Void)?
    /// Skip a looping view's layouts past the break limit instead of letting
    /// AppKit end the app. On in release builds (CrashReporter+Launch).
    public var breaksLoops = false
    public private(set) var reports: [Report] = []
    /// The most layout calls one view had in one turn since launch.
    public private(set) var maxPassesInOneTurn = 0
    /// The view class and window class that had ``maxPassesInOneTurn``
    /// (a busy view below the limit, named before it becomes a loop), and
    /// that window's limit then.
    public private(set) var maxPassesClass: String?
    public private(set) var maxPassesWindowClass: String?
    public private(set) var maxPassesWindowLimit: Int?
    /// Views counted per window at most; a window with this many or more
    /// gets the full ``bound``.
    public static let viewCountCap = 2 * bound
    public private(set) var isInstalled = false

    /// Per view this turn, at its window's frame.
    private var turnCounts: [ObjectIdentifier: Turn] = [:]
    /// Views broken since they last got through a turn without tripping: a
    /// view broken again is not asked to lay out once more, so a loop that
    /// persists settles instead of spinning every frame.
    private var looping: [ObjectIdentifier: Weak] = [:]
    private var classCounts: [ObjectIdentifier: (type: AnyClass, count: Int)] = [:]
    private var reportedClasses: Set<ObjectIdentifier> = []
    /// Limit per window this turn (``limit(viewCount:)``).
    private var windowLimits: [ObjectIdentifier: Int] = [:]
    /// Break limit per window this turn (``breakLimit(viewCount:)``).
    private var windowBreakLimits: [ObjectIdentifier: Int] = [:]
    private var observer: CFRunLoopObserver?
    private static let log = Logger(subsystem: "com.cmuxterm.next", category: "layout-pass-guard")

    private init() {}

    /// Layout calls per view class since launch (counted while installed),
    /// highest first.
    public var passesByClass: [(viewClass: String, passes: Int)] {
        classCounts.values.map { (String(describing: $0.type), $0.count) }.sorted { $0.1 > $1.1 }
    }

    /// Clears the counts and reports (`debug.layers` `reset`, stress runs).
    public func reset() {
        classCounts.removeAll()
        maxPassesInOneTurn = 0
        maxPassesClass = nil
        maxPassesWindowClass = nil
        maxPassesWindowLimit = nil
        reports.removeAll()
        reportedClasses.removeAll()
    }

    /// Installs the counter on `-[NSView layout]` and the per-turn reset on
    /// the main run loop. Idempotent.
    public func install() {
        guard !isInstalled else { return }
        isInstalled = true
        Self.swizzleLayout()
        // Each turn's source phase starts a new count: AppKit's display
        // cycle (and its layout loop) runs inside one source callout.
        let activities = CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { _, _ in
            MainActor.assumeIsolated { LayoutPassGuard.shared.endTurn() } // main-proof: main run loop observer
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func endTurn() {
        if !turnCounts.isEmpty {
            for (id, turn) in turnCounts where !turn.broken { looping[id] = nil }
            turnCounts.removeAll(keepingCapacity: true)
        }
        if !windowLimits.isEmpty { windowLimits.removeAll(keepingCapacity: true) }
        if !windowBreakLimits.isEmpty { windowBreakLimits.removeAll(keepingCapacity: true) }
    }

    /// Whether `view`'s layout call is skipped: broken this turn, at the
    /// same window frame.
    fileprivate func skips(_ view: NSView) -> Bool {
        guard breaksLoops, let turn = turnCounts[ObjectIdentifier(view)] else { return false }
        return turn.broken && turn.view.object === view && turn.windowFrame == (view.window?.frame ?? .zero)
    }

    /// One view's layouts in this turn; the weak reference tells a reused
    /// address apart.
    private struct Turn {
        var view: Weak
        var windowFrame: NSRect
        var count = 0
        /// Layouts since the window last changed frame (the break count).
        var atFrame = 0
        var broken = false
    }

    /// Layout calls of one view in one turn above which the turn is a loop,
    /// for a window of `viewCount` views. AppKit throws when the window
    /// needs pass N+1 after N passes (N = its view count), and a looping
    /// view is laid out in every pass, so the report must come by the view's
    /// N-th call: a window under 8 views reports at N calls (limit N-1, at
    /// least 1); a larger one at half its views, at most ``bound``. A small
    /// window gives up the margin for 1-3 normal calls per turn: a view laid
    /// out N times in an N-view window is at AppKit's own limit already.
    public static func limit(viewCount: Int) -> Int {
        viewCount < 8 ? max(1, viewCount - 1) : min(bound, viewCount / 2)
    }

    /// Layout calls of one view in one turn past which a release build
    /// breaks the loop, for a window of `viewCount` views: three quarters of
    /// them, short of AppKit's limit and far above a busy but finite view (a
    /// titlebar widget lays out about 35 times in one turn after some home
    /// actions), and never under 4: a hosting panel of a few views can
    /// lay out three times in a turn without AppKit throwing.
    public static func breakLimit(viewCount: Int) -> Int {
        max(4, limit(viewCount: viewCount), viewCount * 3 / 4)
    }

    /// `window`'s views (its frame view and every subview), counted up to
    /// `cap`. Reads `subviews` only: no layout.
    public static func viewCount(of window: NSWindow, cap: Int = viewCountCap) -> Int {
        guard let root = window.contentView?.superview ?? window.contentView else { return 0 }
        var views = 0
        var stack: [NSView] = [root]
        while let view = stack.popLast(), views < cap {
            views += 1
            stack.append(contentsOf: view.subviews)
        }
        return views
    }

    /// The limit for `window` this turn, counted once per window per turn.
    private func limit(for window: NSWindow?) -> Int {
        guard let window else { return Self.bound }
        let id = ObjectIdentifier(window)
        if let known = windowLimits[id] { return known }
        let value = Self.limit(viewCount: Self.viewCount(of: window))
        windowLimits[id] = value
        return value
    }

    /// The break limit for `window` this turn, counted (up to 1024 views)
    /// once per window per turn, and only for a view past its report limit.
    /// A view in no window is never broken.
    private func breakLimit(for window: NSWindow?) -> Int {
        guard let window else { return .max }
        let id = ObjectIdentifier(window)
        if let known = windowBreakLimits[id] { return known }
        let value = Self.breakLimit(viewCount: Self.viewCount(of: window, cap: 1024))
        windowBreakLimits[id] = value
        return value
    }

    fileprivate func record(_ view: NSView) {
        let type: AnyClass = Swift.type(of: view)
        let typeID = ObjectIdentifier(type)
        if let entry = classCounts[typeID] {
            classCounts[typeID] = (entry.type, entry.count + 1)
        } else {
            classCounts[typeID] = (type, 1)
        }
        let id = ObjectIdentifier(view)
        let windowFrame = view.window?.frame ?? .zero
        var turn = turnCounts[id].flatMap { $0.view.object === view ? $0 : nil } ?? Turn(view: Weak(view), windowFrame: windowFrame)
        if turn.windowFrame != windowFrame {
            turn.windowFrame = windowFrame
            turn.atFrame = 0
        }
        turn.count += 1
        turn.atFrame += 1
        turnCounts[id] = turn
        let count = turn.count
        if count > maxPassesInOneTurn {
            maxPassesInOneTurn = count
            maxPassesClass = String(describing: type)
            maxPassesWindowClass = view.window.map { String(describing: Swift.type(of: $0)) }
            maxPassesWindowLimit = limit(for: view.window)
        }
        // One call per turn is every view's normal case: no limit lookup.
        guard count > 1 else { return }
        let reportLimit = limit(for: view.window)
        if breaksLoops, turn.atFrame > reportLimit, turn.atFrame == breakLimit(for: view.window) + 1 {
            breakLoop(of: view, id: id, count: turn.atFrame)
        }
        guard count == reportLimit + 1, reportedClasses.insert(typeID).inserted else { return }
        var ancestry: [String] = []
        var next = view.superview
        while let ancestor = next, ancestry.count < 8 {
            ancestry.append(String(describing: Swift.type(of: ancestor)))
            next = ancestor.superview
        }
        let report = Report(viewClass: String(describing: type), windowClass: view.window.map { String(describing: Swift.type(of: $0)) },
                            ancestry: ancestry, passes: count, limit: count - 1, at: Date(), broken: breaksLoops)
        if reports.count >= 32 { reports.removeFirst() }
        reports.append(report)
        Self.log.fault("layout loop: \(report.viewClass, privacy: .public) laid out \(count) times in one turn; window \(report.windowClass ?? "none", privacy: .public); ancestry \(ancestry.joined(separator: " < "), privacy: .public)")
        onLoop?(report)
    }

    /// Skips `view`'s further layouts this turn and, unless it is still
    /// looping from an earlier break, asks for one layout on the next turn.
    private func breakLoop(of view: NSView, id: ObjectIdentifier, count: Int) {
        turnCounts[id]?.broken = true
        Self.log.fault("layout loop broken: \(String(describing: Swift.type(of: view)), privacy: .public) after \(count) layouts in one turn")
        guard looping[id]?.object !== view else { return }
        looping = looping.filter { $0.value.object != nil }
        looping[id] = Weak(view)
        DispatchQueue.main.async { [weak view] in
            // main-proof: DispatchQueue.main runs its blocks on the main thread
            MainActor.assumeIsolated { view?.needsLayout = true }
        }
    }

    struct Weak {
        weak var object: NSView?
        init(_ object: NSView) { self.object = object }
    }

    private typealias Layout = @convention(c) (NSView, Selector) -> Void

    private static func swizzleLayout() {
        let selector = #selector(NSView.layout)
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Layout.self)
        method_setImplementation(method, imp_implementationWithBlock(override(calling: original, selector)))
    }

    /// Built outside the main actor so the block carries no isolation
    /// check: AppKit lays out on the main thread, and a view laid out
    /// elsewhere is passed through uncounted.
    private nonisolated static func override(calling original: Layout, _ selector: Selector) -> @convention(block) (NSView) -> Void {
        { view in
            guard Thread.isMainThread else { return original(view, selector) }
            // main-proof: checked above
            if MainActor.assumeIsolated({ LayoutPassGuard.shared.skips(view) }) { return }
            original(view, selector)
            MainActor.assumeIsolated { LayoutPassGuard.shared.record(view) } // main-proof: checked above
        }
    }
}
