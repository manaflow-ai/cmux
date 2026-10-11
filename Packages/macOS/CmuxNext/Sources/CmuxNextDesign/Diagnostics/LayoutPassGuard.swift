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
/// The guard counts layout calls per view in one run-loop turn, restarting
/// when the view's window changes frame: an animated resize (zoom) lays the
/// window out once per frame inside one turn. It wraps `-[NSView layout]` and,
/// the first time a view's `super.layout()` reaches it, every `layout`
/// override in that view's class chain, so a call counts once at its
/// outermost override (an override that never calls super stays invisible).
/// A normal turn lays out a view one to three times. When one
/// view passes ``bound`` in one turn, the guard records a ``Report`` with
/// the view's class, its superview chain and its window class, logs a fault
/// and calls ``onLoop`` (the app sends it to Sentry as a non-fatal event).
/// One report per view class per launch. Reading: ``reports``,
/// ``passesByClass``, ``maxPassesInOneTurn`` (`debug.layers`).
///
/// With ``breaksLoops`` (release builds) the guard also ends the loop: past
/// the limit, the view's further layouts in that turn are skipped and one
/// layout is asked for on the next turn, so AppKit never reaches its own
/// limit and the app keeps running. Skipping happens at the outermost
/// override, so the looping override's own code does not run either. The
/// limit is ``bound``, or fewer in a window with fewer views, where AppKit
/// gives up sooner, but never under 4. Debug
/// builds leave it off, so a loop still ends the app where it can be fixed.
@MainActor
public final class LayoutPassGuard {
    public struct Report: Sendable, Equatable {
        public var viewClass: String
        public var windowClass: String?
        /// Superview classes, nearest first (at most 8).
        public var ancestry: [String]
        /// Layout passes of the view in the turn when the bound was passed.
        public var passes: Int
        public var at: Date
        /// The guard skipped the view's further layouts (``breaksLoops``).
        public var broken = false
    }

    public static let shared = LayoutPassGuard()

    /// Layout calls of one view in one run-loop turn above which the turn
    /// is a loop. Well below AppKit's own limit (one pass per view in the
    /// window), well above a normal turn.
    public static let bound = 16

    /// A loop was found (main thread, once per view class per launch).
    public var onLoop: ((Report) -> Void)?
    /// Skip a looping view's layouts past the limit instead of letting
    /// AppKit end the app. On in release builds (CrashReporter+Launch).
    public var breaksLoops = false
    public private(set) var reports: [Report] = []
    /// The most layout calls one view had in one turn since launch.
    public private(set) var maxPassesInOneTurn = 0
    public private(set) var isInstalled = false

    /// Per view this turn, at its window's frame; the weak reference tells a
    /// reused address apart.
    private var turnCounts: [ObjectIdentifier: (view: Weak, count: Int, broken: Bool, windowFrame: NSRect)] = [:]
    /// Views broken in the last turn: a view broken again is not asked to
    /// lay out once more, so a loop that persists settles instead of
    /// spinning every turn.
    private var brokenLastTurn: Set<ObjectIdentifier> = []
    /// Views inside a counted layout call: their inner overrides and
    /// `super.layout()` pass through.
    private var inLayout: Set<ObjectIdentifier> = []
    private var wrapped: Set<ObjectIdentifier> = []
    private var classCounts: [ObjectIdentifier: (type: AnyClass, count: Int)] = [:]
    private var reportedClasses: Set<ObjectIdentifier> = []
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
        inLayout.removeAll()
        guard !turnCounts.isEmpty else {
            brokenLastTurn.removeAll()
            return
        }
        brokenLastTurn = Set(turnCounts.filter { $0.value.broken }.keys)
        turnCounts.removeAll(keepingCapacity: true)
    }

    fileprivate enum Entry { case outermost, inner, skipped }

    /// How a layout call of `view` runs: counted (the outermost), passed
    /// through (inside a counted call), or skipped (broken this turn).
    fileprivate func enter(_ view: NSView) -> Entry {
        let id = ObjectIdentifier(view)
        if inLayout.contains(id) { return .inner }
        wrapOverrides(of: Swift.type(of: view))
        if breaksLoops, let entry = turnCounts[id], entry.broken, entry.view.object === view,
           entry.windowFrame == (view.window?.frame ?? .zero) { return .skipped }
        inLayout.insert(id)
        return .outermost
    }

    fileprivate func exit(_ view: NSView) {
        inLayout.remove(ObjectIdentifier(view))
        record(view)
    }

    /// Wraps each class from `type` up to NSView that defines its own `layout`.
    private func wrapOverrides(of type: AnyClass) {
        var next: AnyClass? = type
        while let cls = next, ObjectIdentifier(cls) != ObjectIdentifier(NSView.self), wrapped.insert(ObjectIdentifier(cls)).inserted {
            if Self.definesLayout(cls) { Self.wrapLayout(of: cls) }
            next = class_getSuperclass(cls)
        }
    }

    /// Layouts of one view in one turn past which the turn is a loop:
    /// ``bound``, or two less than the window's view count when that is
    /// lower (AppKit allows one pass per view, and the guard must act
    /// first), but never under 4: a third layout in a turn is normal. The
    /// walk stops past ``bound`` views.
    private func limit(for view: NSView) -> Int {
        guard let root = view.window?.contentView?.superview ?? view.window?.contentView else { return Self.bound }
        var count = 0
        var stack = [root]
        while let next = stack.popLast(), count <= Self.bound {
            count += 1
            stack.append(contentsOf: next.subviews)
        }
        return min(Self.bound, max(4, count - 2))
    }

    private func record(_ view: NSView) {
        let type: AnyClass = Swift.type(of: view)
        let typeID = ObjectIdentifier(type)
        if let entry = classCounts[typeID] {
            classCounts[typeID] = (entry.type, entry.count + 1)
        } else {
            classCounts[typeID] = (type, 1)
        }
        let id = ObjectIdentifier(view)
        let windowFrame = view.window?.frame ?? .zero
        var count = 1
        if let entry = turnCounts[id], entry.view.object === view, entry.windowFrame == windowFrame { count = entry.count + 1 }
        turnCounts[id] = (Weak(view), count, false, windowFrame)
        if count > maxPassesInOneTurn { maxPassesInOneTurn = count }
        // A normal turn lays a view out at most three times; only more walks the window.
        guard count > 4, count == limit(for: view) + 1 else { return }
        if breaksLoops { breakLoop(of: view, id: id, count: count) }
        guard reportedClasses.insert(typeID).inserted else { return }
        var ancestry: [String] = []
        var next = view.superview
        while let ancestor = next, ancestry.count < 8 {
            ancestry.append(String(describing: Swift.type(of: ancestor)))
            next = ancestor.superview
        }
        let report = Report(viewClass: String(describing: type), windowClass: view.window.map { String(describing: Swift.type(of: $0)) },
                            ancestry: ancestry, passes: count, at: Date(), broken: breaksLoops)
        if reports.count >= 32 { reports.removeFirst() }
        reports.append(report)
        Self.log.fault("layout loop: \(report.viewClass, privacy: .public) laid out \(count) times in one turn; window \(report.windowClass ?? "none", privacy: .public); ancestry \(ancestry.joined(separator: " < "), privacy: .public)")
        onLoop?(report)
    }

    /// Skips `view`'s further layouts this turn and, unless it was broken
    /// last turn too, asks for one layout on the next turn.
    private func breakLoop(of view: NSView, id: ObjectIdentifier, count: Int) {
        turnCounts[id] = (Weak(view), count, true, view.window?.frame ?? .zero)
        guard !brokenLastTurn.contains(id) else { return }
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
        wrapLayout(of: NSView.self)
    }

    private static func definesLayout(_ cls: AnyClass) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        return (0..<Int(count)).contains { method_getName(methods[$0]) == #selector(NSView.layout) }
    }

    private static func wrapLayout(of cls: AnyClass) {
        let selector = #selector(NSView.layout)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
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
            switch MainActor.assumeIsolated({ LayoutPassGuard.shared.enter(view) }) {
            case .skipped:
                return
            case .inner:
                original(view, selector)
            case .outermost:
                original(view, selector)
                MainActor.assumeIsolated { LayoutPassGuard.shared.exit(view) } // main-proof: checked above
            }
        }
    }
}
