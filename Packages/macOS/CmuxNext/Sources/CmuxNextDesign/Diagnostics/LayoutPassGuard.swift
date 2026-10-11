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
    }

    public static let shared = LayoutPassGuard()

    /// Layout calls of one view in one run-loop turn above which the turn
    /// is a loop. Well below AppKit's own limit (one pass per view in the
    /// window), well above a normal turn.
    public static let bound = 16

    /// A loop was found (main thread, once per view class per launch).
    public var onLoop: ((Report) -> Void)?
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
    static let viewCountCap = 2 * bound
    public private(set) var isInstalled = false

    /// Per view this turn; the weak reference tells a reused address apart.
    private var turnCounts: [ObjectIdentifier: (view: Weak, count: Int)] = [:]
    private var classCounts: [ObjectIdentifier: (type: AnyClass, count: Int)] = [:]
    private var reportedClasses: Set<ObjectIdentifier> = []
    /// Limit per window this turn (``limit(viewCount:)``).
    private var windowLimits: [ObjectIdentifier: Int] = [:]
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
        if !turnCounts.isEmpty { turnCounts.removeAll(keepingCapacity: true) }
        if !windowLimits.isEmpty { windowLimits.removeAll(keepingCapacity: true) }
    }

    /// Layout calls of one view in one turn above which the turn is a loop,
    /// for a window of `viewCount` views. AppKit throws when the window
    /// needs pass N+1 after N passes (N = its view count), and a looping
    /// view is laid out in every pass, so the report must come by the view's
    /// N-th call: a window under 8 views reports at N calls (limit N-1, at
    /// least 1); a larger one at half its views, at most ``bound``. A small
    /// window gives up the margin for 1-3 normal calls per turn: a view laid
    /// out N times in an N-view window is at AppKit's own limit already.
    public nonisolated static func limit(viewCount: Int) -> Int {
        viewCount < 8 ? max(1, viewCount - 1) : min(bound, viewCount / 2)
    }

    /// `window`'s views (its frame view and every subview), counted up to
    /// ``viewCountCap``. Reads `subviews` only: no layout.
    public static func viewCount(of window: NSWindow) -> Int {
        guard let root = window.contentView?.superview ?? window.contentView else { return 0 }
        var views = 0
        var stack: [NSView] = [root]
        while let view = stack.popLast(), views < viewCountCap {
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

    fileprivate func record(_ view: NSView) {
        let type: AnyClass = Swift.type(of: view)
        let typeID = ObjectIdentifier(type)
        if let entry = classCounts[typeID] {
            classCounts[typeID] = (entry.type, entry.count + 1)
        } else {
            classCounts[typeID] = (type, 1)
        }
        let id = ObjectIdentifier(view)
        var count = 1
        if let entry = turnCounts[id], entry.view.object === view { count = entry.count + 1 }
        turnCounts[id] = (Weak(view), count)
        if count > maxPassesInOneTurn {
            maxPassesInOneTurn = count
            maxPassesClass = String(describing: type)
            maxPassesWindowClass = view.window.map { String(describing: Swift.type(of: $0)) }
            maxPassesWindowLimit = limit(for: view.window)
        }
        // One call per turn is every view's normal case: no limit lookup.
        guard count > 1, count == limit(for: view.window) + 1, reportedClasses.insert(typeID).inserted else { return }
        var ancestry: [String] = []
        var next = view.superview
        while let ancestor = next, ancestry.count < 8 {
            ancestry.append(String(describing: Swift.type(of: ancestor)))
            next = ancestor.superview
        }
        let report = Report(viewClass: String(describing: type), windowClass: view.window.map { String(describing: Swift.type(of: $0)) },
                            ancestry: ancestry, passes: count, limit: count - 1, at: Date())
        if reports.count >= 32 { reports.removeFirst() }
        reports.append(report)
        Self.log.fault("layout loop: \(report.viewClass, privacy: .public) laid out \(count) times in one turn; window \(report.windowClass ?? "none", privacy: .public); ancestry \(ancestry.joined(separator: " < "), privacy: .public)")
        onLoop?(report)
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
            original(view, selector)
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { LayoutPassGuard.shared.record(view) } // main-proof: checked above
        }
    }
}
