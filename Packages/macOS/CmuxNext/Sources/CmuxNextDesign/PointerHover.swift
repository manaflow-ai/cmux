public import AppKit

/// Hover as a function of where the pointer is now and where the view is
/// now (cx-ww20, cx-3wu5). A tracking area reports only pointer moves: when
/// a layout pass, a scroll, a collapse or a hide moves a view under a still
/// pointer, no exit arrives and an enter/exit-driven hover stays lit. So a
/// view keeps no hover of its own: it owns a `PointerHover`, and the hover
/// is recomputed from the pointer and the current frames after
///
/// - every enter or exit of any target in the window (its own tracking area,
///   owned by the target, not the view),
/// - every geometry or visibility change, reported by the view that owns the
///   geometry (`PointerHover.refresh(in:)`: a sidebar layout pass, a toast
///   relayout, a strip scrollbar update),
/// - every key-window change, and every `debug.mouse` pointer (DEBUG).
///
/// The layout's divider hover (`ScreenDividers`) reads the same pointer.
@MainActor
public final class PointerHover: NSObject {
    /// Whether the pointer is over the view now (as of the last refresh).
    public private(set) var isHovering = false
    /// Runs after `isHovering` changes.
    public var onChange: ((Bool) -> Void)?
    /// Hover is allowed now besides the geometry (a control is enabled, a
    /// scrollbar is shown). Call `refresh()` when the answer changes.
    public var isHoverable: () -> Bool = { true }
    /// The hover region in the view's coordinates (default: its bounds).
    public var region: ((NSView) -> CGRect)?
    /// Windows above the view's window that pass hover through (click-catching panels over
    /// page windows): the topmost check treats them as the view's window.
    public var passThroughWindows: () -> Set<Int> = { [] }
    public let requiresKeyWindow: Bool

    fileprivate weak var view: NSView?
    private var area: NSTrackingArea?
    /// The view's identifier, for the index's entry (read in `deinit`, after the view may be gone).
    private let viewKey: ObjectIdentifier

    /// - Parameter requiresKeyWindow: false for window chrome (hover shows in
    ///   a background window, as in the sidebar), true for sheets.
    public init(_ view: NSView, requiresKeyWindow: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.view = view
        viewKey = ObjectIdentifier(view)
        self.requiresKeyWindow = requiresKeyWindow
        self.onChange = onChange
        super.init()
        // `.inVisibleRect` follows the view's visible rect, so the area never
        // needs replacing; the view's own `updateTrackingAreas` leaves it alone
        // (it removes only areas it owns).
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, requiresKeyWindow ? .activeInKeyWindow : .activeAlways, .inVisibleRect],
                                  owner: self)
        view.addTrackingArea(area)
        self.area = area
        Self.index.insert(self, view: view)
        Self.installKeyObserversIfNeeded()
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let area { view?.removeTrackingArea(area) }
            Self.index.remove(ObjectIdentifier(self), view: viewKey)
        }
    }

    // MARK: Events

    // AppKit sends a tracking area's owner `mouseEntered:` and `mouseExited:`.
    // This owner is not an NSResponder, so the selectors must be named: a bare
    // `@objc` exports `mouseEnteredWith:`, and the first enter raised
    // NSInvalidArgumentException in `_dispatchMouseEntered:` (cx-2mp6).
    // The target's own event refreshes the window its view is in now.
    @objc(mouseEntered:) public func mouseEntered(with event: NSEvent) {
        Self.refresh(in: view?.window)
    }
    @objc(mouseExited:) public func mouseExited(with event: NSEvent) {
        Self.refresh(in: view?.window)
    }

    /// Recomputes this target only (its eligibility changed).
    public func refresh() {
        update()
    }

    private func update() {
        let hovering = computeHovering()
        guard hovering != isHovering else { return }
        isHovering = hovering
        Self.index.noteHovering(self, hovering)
        onChange?(hovering)
    }

    /// The target's creation order (a refresh runs its targets in it).
    fileprivate var order: UInt64 = 0

    private func computeHovering() -> Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor, isHoverable(),
              let pointer = Self.pointer(in: window, requireKey: requiresKeyWindow) else { return false }
        let local = view.convert(pointer, from: nil)
        let rect = (region?(view) ?? view.bounds).intersection(view.visibleRect)
        guard !rect.isNull, rect.contains(local) else { return false }
        return Self.isTopmost(window, passThrough: passThroughWindows())
    }

    // MARK: The pointer

    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEBUG (`debug.mouse`, tests): the pointer synthesized per window, in
    /// window coordinates (`point` nil: outside the window), and where the
    /// real mouse was then. A window with a synthesized pointer ignores the
    /// real one until the real mouse moves (the user takes over) or the
    /// window closes.
    struct DebugPointer {
        var point: NSPoint?
        var mouse: NSPoint
    }

    static var debugPointers: [ObjectIdentifier: DebugPointer] = [:]

    /// DEBUG: sets `window`'s synthesized pointer (nil: outside the window),
    /// then recomputes every target in the window.
    public static func setDebugPointer(_ point: NSPoint?, in window: NSWindow) {
        debugPointers[ObjectIdentifier(window)] = DebugPointer(point: point, mouse: NSEvent.mouseLocation)
        installKeyObserversIfNeeded()
        refresh(in: window)
    }

    /// DEBUG: the synthesized pointer of `window` while it holds: `.some(nil)`
    /// is a pointer outside the window, nil is no synthesized pointer.
    static func debugPointer(in window: NSWindow) -> NSPoint?? {
        let key = ObjectIdentifier(window)
        guard let entry = debugPointers[key] else { return nil }
        guard entry.mouse == NSEvent.mouseLocation else {
            // The real mouse moved since: the user's pointer counts again.
            debugPointers[key] = nil
            return nil
        }
        return .some(entry.point)
    }

    #endif

    /// The pointer in `window`'s coordinates; nil when the window is not
    /// shown (or, with `requireKey`, not key). `debug.mouse`'s synthesized
    /// pointer wins in DEBUG builds.
    public static func pointer(in window: NSWindow, requireKey: Bool = false) -> NSPoint? {
        #if DEBUG
        if let synthetic = debugPointer(in: window) { return synthetic }
        #endif
        guard window.isVisible, !requireKey || window.isKeyWindow else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    /// The topmost window that takes the mouse under the real pointer is
    /// `window` or one of `passThrough` (no other window or panel covers the
    /// point). A window server round trip: ask only when a view is under the
    /// pointer.
    public static func isTopmost(_ window: NSWindow, passThrough: Set<Int> = []) -> Bool {
        #if DEBUG
        if debugPointer(in: window) != nil { return true }
        #endif
        let top = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return top == window.windowNumber || passThrough.contains(top)
    }

    // MARK: The owner

    private static let index = TargetIndex()
    private static var refreshing = false
    private static var pending: [NSWindow] = []
    private static var keyObserver: KeyWindowObserver?

    /// Recomputes `window`'s hover from the pointer and the current frames: the targets that
    /// hover now (anywhere: a view that left its window or hid must clear), then the targets whose
    /// views are under the pointer in `window` (`TargetIndex.candidates(in:)`). O(hovering +
    /// the views on the pointer's path), never O(targets): a sidebar layout pass calls it, and a
    /// scan of every target there made each layout pass cost every view in the app (the
    /// 2026-10-30 full-suite hang). Call after anything moves, hides or reflows views under a
    /// possibly still pointer. A refresh that an `onChange` starts (a hover that expands a
    /// stack) runs right after the current one.
    public static func refresh(in window: NSWindow?) {
        guard let window else { return }
        guard !refreshing else {
            if !pending.contains(where: { $0 === window }) { pending.append(window) }
            return
        }
        refreshing = true
        defer { refreshing = false }
        var queue = [window]
        // Bounded: a hover that moves its own view away and back must not spin.
        var passes = 0
        while !queue.isEmpty, passes < 8 {
            passes += 1
            let current = queue.removeFirst()
            for target in index.candidates(in: current) { target.update() }
            queue.append(contentsOf: pending)
            pending.removeAll()
        }
    }

    /// A key-window change refreshes that window (a key-window target under the pointer starts or
    /// ends; the hovering ones elsewhere are recomputed with it).
    fileprivate static func keyChanged(_ window: NSWindow?) {
        refresh(in: window)
    }

    /// Becoming or resigning key changes whether key-window targets hover.
    private static func installKeyObserversIfNeeded() {
        guard keyObserver == nil else { return }
        keyObserver = KeyWindowObserver()
    }
}

/// Key-window changes refresh that window's hover (`PointerHover`).
///
/// Block observers on `queue: .main`, not selectors: AppKit may post these
/// off the main thread, and a selector into this main-actor class trapped
/// there (#18771). `queue: .main` runs the block inline when the post is on
/// main, so key changes and closes keep their synchronous order.
@MainActor
private final class KeyWindowObserver {
    private var tokens: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { PointerHover.keyChanged(window) } // main-proof: observer on queue: .main
            })
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        // A closed window's synthesized pointer must not pass to a new window
        // that reuses its address.
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            let key = ObjectIdentifier(window)
            MainActor.assumeIsolated { PointerHover.debugPointers[key] = nil } // main-proof: observer on queue: .main
        })
        #endif
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// `PointerHover`'s targets by view, and the ones that hover now. A refresh of a window reads the
/// hovering targets (a handful) and the targets of the views under the pointer there, found by a
/// walk down the window's view tree along the pointer, as Chromium's `RootView` finds a mouse
/// move's handler (`GetEventHandlerForPoint`) and `Widget::SynthesizeMouseMoveEvent` replays the
/// last mouse location after a layout. It never reads every target: the index changes only when a
/// target is made or freed (O(1) each), and a view that moves into, out of or between windows
/// needs no notice, since the walk sees where the views are now.
///
/// Before (cx-8w027.10 item c), each refresh read every target of the window plus every target
/// whose view had no window (detached rows, the chrome of a closed tab, views made before their
/// window), filed each again and sorted them all; a sidebar layout pass refreshes, so every layout
/// pass cost every view the process kept, and the full suite's main thread spent its time there.
@MainActor
private final class TargetIndex {
    private struct Weak {
        weak var value: PointerHover?
    }

    /// The targets of each view (one, now and then two), by the view's identifier.
    private var byView: [ObjectIdentifier: [Weak]] = [:]
    /// Targets that hover now (a handful).
    private var hovering: [ObjectIdentifier: Weak] = [:]
    private var nextOrder: UInt64 = 0
    /// The entry count at which freed entries are swept (a target freed off the main thread
    /// leaves its entry): twice the count after the last sweep, so sweeps cost O(1) a target.
    private var sweepAt = 256

    func insert(_ target: PointerHover, view: NSView) {
        nextOrder &+= 1
        target.order = nextOrder
        let key = ObjectIdentifier(view)
        // A freed view's identifier reused by this one: its old entries go.
        var entries = byView[key, default: []].filter { $0.value?.view === view }
        entries.append(Weak(value: target))
        byView[key] = entries
        if byView.count >= sweepAt { sweep() }
    }

    /// A target is freed (its `deinit`, on the main thread): its entries drop out.
    func remove(_ target: ObjectIdentifier, view: ObjectIdentifier) {
        hovering[target] = nil
        guard let entries = byView[view] else { return }
        let live = entries.filter { $0.value != nil }
        byView[view] = live.isEmpty ? nil : live
    }

    func noteHovering(_ target: PointerHover, _ hovers: Bool) {
        hovering[ObjectIdentifier(target)] = hovers ? Weak(value: target) : nil
    }

    /// The targets a refresh of `window` reads: the ones that hover now, then the ones whose view
    /// is under the pointer in `window`, each group in creation order (a hover that ends runs
    /// before one that starts). Without a pointer in `window` (not shown, or outside it) only the
    /// hovering ones, which then clear.
    func candidates(in window: NSWindow) -> [PointerHover] {
        var seen = Set<ObjectIdentifier>()
        var ending: [(order: UInt64, target: PointerHover)] = []
        for (id, entry) in hovering {
            guard let target = entry.value else {
                hovering[id] = nil
                continue
            }
            seen.insert(id)
            ending.append((target.order, target))
        }
        var starting: [(order: UInt64, target: PointerHover)] = []
        if let point = PointerHover.pointer(in: window) {
            for view in Self.views(under: point, in: window) {
                for entry in byView[ObjectIdentifier(view)] ?? [] {
                    guard let target = entry.value, target.view === view, seen.insert(ObjectIdentifier(target)).inserted else { continue }
                    starting.append((target.order, target))
                }
            }
        }
        ending.sort { $0.order < $1.order }
        starting.sort { $0.order < $1.order }
        return ending.map(\.target) + starting.map(\.target)
    }

    /// The shown views of `window` that contain `point` (window coordinates), from the window's
    /// root view down. Every subview whose frame contains the point is entered, overlapping
    /// siblings too (each target hovers by its own rect, also under a sibling). A hidden view and
    /// its subviews are skipped (they cannot hover), and so is a view outside its superview's
    /// bounds there (its visible rect, and AppKit's own hit test, leave it out).
    static func views(under point: NSPoint, in window: NSWindow) -> [NSView] {
        guard var root = window.contentView else { return [] }
        while let up = root.superview { root = up }
        let start = root.convert(point, from: nil)
        guard !root.isHidden, root.bounds.contains(start) else { return [] }
        var found: [NSView] = []
        var stack: [(view: NSView, point: NSPoint)] = [(root, start)]
        while let next = stack.popLast() {
            found.append(next.view)
            for sub in next.view.subviews where !sub.isHidden && sub.frame.contains(next.point) {
                stack.append((sub, sub.convert(next.point, from: next.view)))
            }
        }
        return found
    }

    /// Drops the entries of freed targets.
    private func sweep() {
        for (key, entries) in byView {
            let live = entries.filter { $0.value != nil }
            if live.count != entries.count { byView[key] = live.isEmpty ? nil : live }
        }
        sweepAt = max(256, byView.count * 2)
    }
}
