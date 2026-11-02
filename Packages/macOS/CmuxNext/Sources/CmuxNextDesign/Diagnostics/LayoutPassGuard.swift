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
/// AppKit counts those passes inside one `-[NSWindow layoutIfNeeded]` (the
/// display cycle calls it once per window per frame), so the guard counts
/// the same way: `-[NSView layout]` calls per view inside one
/// `layoutIfNeeded` of its window (an override that calls `super.layout()`
/// counts; one that does not is invisible). A view laid out outside a
/// window layout (an explicit `layoutSubtreeIfNeeded`) does not count, as
/// it does not count for AppKit. A normal window layout lays a view out
/// once, twice when a layout converges in a second pass. When one view
/// passes its window's limit (``limit(viewCount:)``: ``bound``, lower in a
/// window of few views, because AppKit's limit is the window's view count),
/// the guard records a ``Report`` with the view's class, its superview
/// chain and its window class, logs a fault and calls ``onLoop`` (the app
/// sends it to Sentry as a non-fatal event). One report per view class per
/// launch. Reading: ``reports``, ``passesByClass``, ``maxPassesInOneTurn``
/// (`debug.layers`).
@MainActor
public final class LayoutPassGuard {
    public struct Report: Sendable, Equatable {
        public var viewClass: String
        public var windowClass: String?
        /// Superview classes, nearest first (at most 8).
        public var ancestry: [String]
        /// Layout calls of the view in the window layout when the limit was passed.
        public var passes: Int
        /// The window's limit then (``LayoutPassGuard/limit(viewCount:)``):
        /// below ``LayoutPassGuard/bound`` only in a small window.
        public var limit: Int
        public var at: Date
    }

    public static let shared = LayoutPassGuard()

    /// Layout calls of one view in one window layout above which the window
    /// loops. Well below AppKit's own limit in a window of many views, well
    /// above a normal window layout (one or two calls).
    public static let bound = 16

    /// A loop was found (main thread, once per view class per launch).
    public var onLoop: ((Report) -> Void)?
    public private(set) var reports: [Report] = []
    /// The most layout calls one view had in one window layout since launch.
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
    /// `-[NSView layout]` calls and window layout passes that laid out a view
    /// (outermost `layoutIfNeeded` only), since launch, all windows: plain
    /// counters a probe reads as deltas (`debug.frames` per frame). Counted in
    /// every build the guard is installed in: the bench and recording builds are
    /// not DEBUG, and a DEBUG-only count read 0 there, so a frame trace said
    /// "no layout" for frames that laid out every resized pane (RESIZE VIDEOS F1).
    /// One integer add per layout call, beside the class count every build keeps.
    public private(set) var viewLayoutCalls = 0
    public private(set) var windowLayoutPasses = 0

    /// One `layoutIfNeeded` of a window in progress: its nesting depth, the
    /// layout calls per view in it (the weak reference tells a reused
    /// address apart) and the window's limit once looked up.
    private struct WindowLayout {
        var depth = 0
        /// `viewLayoutCalls` when the outermost pass began.
        var viewCallsAtStart = 0
        var counts: [ObjectIdentifier: (view: Weak, count: Int)] = [:]
        var limit: Int?
    }

    private var windowLayouts: [ObjectIdentifier: WindowLayout] = [:]
    private var classCounts: [ObjectIdentifier: (type: AnyClass, count: Int)] = [:]
    private var reportedClasses: Set<ObjectIdentifier> = []
    private var observer: CFRunLoopObserver?
    private static let log = Logger(subsystem: "com.cmuxterm.next", category: "layout-pass-guard")

    private init() {}

    /// Layout calls per view class since launch (counted while installed,
    /// inside and outside window layouts), highest first.
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

    /// Installs the counters on `-[NSView layout]` and
    /// `-[NSWindow layoutIfNeeded]`. Idempotent.
    public func install() {
        guard !isInstalled else { return }
        isInstalled = true
        Self.swizzleLayout()
        Self.swizzleWindowLayout()
        // No window layout runs while the main run loop waits: an entry left
        // then leaked (AppKit's layout exception skipped its end) and goes.
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { LayoutPassGuard.shared.dropLeakedWindowLayouts() } // main-proof: main run loop observer
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func dropLeakedWindowLayouts() {
        if !windowLayouts.isEmpty { windowLayouts.removeAll() }
    }

    /// Layout calls of one view in one window layout above which the window
    /// loops, for a window of `viewCount` views. AppKit throws when the
    /// window needs pass N+1 after N passes (N = its view count), and a
    /// looping view is laid out in every pass, so the report must come by
    /// the view's N-th call: a window under 8 views reports at N calls
    /// (limit N-1), a larger one at half its views, at most ``bound``. The
    /// limit is at least 2, so a layout that converges in a second pass
    /// never reports: a window of 1 or 2 views throws before a report.
    public static func limit(viewCount: Int) -> Int {
        viewCount < 8 ? max(2, viewCount - 1) : min(bound, viewCount / 2)
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

    fileprivate func windowLayoutWillBegin(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        windowLayouts[id, default: WindowLayout()].depth += 1
        if windowLayouts[id]?.depth == 1 { windowLayouts[id]?.viewCallsAtStart = viewLayoutCalls }
    }

    fileprivate func windowLayoutDidEnd(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard var layout = windowLayouts[id] else { return }
        layout.depth -= 1
        if layout.depth == 0, viewLayoutCalls != layout.viewCallsAtStart { windowLayoutPasses &+= 1 }
        windowLayouts[id] = layout.depth > 0 ? layout : nil
    }

    fileprivate func record(_ view: NSView) {
        viewLayoutCalls &+= 1
        let type: AnyClass = Swift.type(of: view)
        let typeID = ObjectIdentifier(type)
        if let entry = classCounts[typeID] {
            classCounts[typeID] = (entry.type, entry.count + 1)
        } else {
            classCounts[typeID] = (type, 1)
        }
        guard let window = view.window else { return }
        let windowID = ObjectIdentifier(window)
        guard windowLayouts[windowID] != nil else { return }
        let id = ObjectIdentifier(view)
        var count = 1
        // In place (no copy of the window's counts per call).
        if let entry = windowLayouts[windowID]?.counts[id], entry.view.object === view { count = entry.count + 1 }
        windowLayouts[windowID]?.counts[id] = (Weak(view), count)
        // One call per window layout is every view's normal case: no limit lookup.
        var limit: Int?
        if count > 1 || count > maxPassesInOneTurn {
            let known = windowLayouts[windowID]?.limit ?? Self.limit(viewCount: Self.viewCount(of: window))
            windowLayouts[windowID]?.limit = known
            limit = known
        }
        if count > maxPassesInOneTurn {
            maxPassesInOneTurn = count
            maxPassesClass = String(describing: type)
            maxPassesWindowClass = String(describing: Swift.type(of: window))
            maxPassesWindowLimit = limit
        }
        guard let limit, count == limit + 1, reportedClasses.insert(typeID).inserted else { return }
        var ancestry: [String] = []
        var next = view.superview
        while let ancestor = next, ancestry.count < 8 {
            ancestry.append(String(describing: Swift.type(of: ancestor)))
            next = ancestor.superview
        }
        let report = Report(viewClass: String(describing: type), windowClass: String(describing: Swift.type(of: window)),
                            ancestry: ancestry, passes: count, limit: limit, at: Date())
        if reports.count >= 32 { reports.removeFirst() }
        reports.append(report)
        Self.log.fault("layout loop: \(report.viewClass, privacy: .public) laid out \(count) times in one window layout; window \(report.windowClass ?? "none", privacy: .public); ancestry \(ancestry.joined(separator: " < "), privacy: .public)")
        onLoop?(report)
    }

    struct Weak {
        weak var object: NSView?
        init(_ object: NSView) { self.object = object }
    }

    private typealias Layout = @convention(c) (NSView, Selector) -> Void
    private typealias WindowLayoutIMP = @convention(c) (NSWindow, Selector) -> Void

    private static func swizzleLayout() {
        let selector = #selector(NSView.layout)
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Layout.self)
        method_setImplementation(method, imp_implementationWithBlock(override(calling: original, selector)))
    }

    private static func swizzleWindowLayout() {
        let selector = #selector(NSWindow.layoutIfNeeded)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: WindowLayoutIMP.self)
        method_setImplementation(method, imp_implementationWithBlock(windowOverride(calling: original, selector)))
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

    /// Brackets one `layoutIfNeeded` of a window (AppKit's unit for its
    /// pass limit); off the main thread it passes through.
    private nonisolated static func windowOverride(calling original: WindowLayoutIMP,
                                                   _ selector: Selector) -> @convention(block) (NSWindow) -> Void {
        { window in
            guard Thread.isMainThread else { return original(window, selector) }
            MainActor.assumeIsolated { LayoutPassGuard.shared.windowLayoutWillBegin(window) } // main-proof: checked above
            original(window, selector)
            MainActor.assumeIsolated { LayoutPassGuard.shared.windowLayoutDidEnd(window) } // main-proof: checked above
        }
    }
}
