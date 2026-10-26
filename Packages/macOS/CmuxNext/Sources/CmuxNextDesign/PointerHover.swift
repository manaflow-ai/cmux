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

    private weak var view: NSView?
    private var area: NSTrackingArea?

    /// - Parameter requiresKeyWindow: false for window chrome (hover shows in
    ///   a background window, as in the sidebar), true for sheets.
    public init(_ view: NSView, requiresKeyWindow: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.view = view
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
        Self.index.insert(self)
        Self.installKeyObserversIfNeeded()
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let area { view?.removeTrackingArea(area) }
        }
    }

    // MARK: Events

    // AppKit sends a tracking area's owner `mouseEntered:` and `mouseExited:`.
    // This owner is not an NSResponder, so the selectors must be named: a bare
    // `@objc` exports `mouseEnteredWith:`, and the first enter raised
    // NSInvalidArgumentException in `_dispatchMouseEntered:` (cx-2mp6).
    // The target's own event files it under its window first: a view moved to another window
    // since the last refresh is found there.
    @objc(mouseEntered:) public func mouseEntered(with event: NSEvent) {
        Self.index.place(self)
        Self.refresh(in: view?.window)
    }
    @objc(mouseExited:) public func mouseExited(with event: NSEvent) {
        Self.index.place(self)
        Self.refresh(in: view?.window)
    }

    /// Recomputes this target only (its eligibility changed).
    public func refresh() {
        Self.index.place(self)
        update()
    }

    private func update() {
        let hovering = computeHovering()
        guard hovering != isHovering else { return }
        isHovering = hovering
        Self.index.noteHovering(self, hovering)
        onChange?(hovering)
    }

    /// The window the index files this target under (nil: no window when last seen), and the
    /// target's creation order (refreshes run targets in it).
    fileprivate var indexedWindow: ObjectIdentifier?
    fileprivate var order: UInt64 = 0
    /// The view's window; nil while that window deallocates (its teardown moves the view out, and
    /// a weak reference to it aborts the runtime: "Cannot form weak reference to instance").
    fileprivate var viewWindow: NSWindow? {
        guard let window = view?.window, !window.isBeingDeallocated else { return nil }
        return window
    }

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

    /// Recomputes every target in `window` from the pointer and the current frames: O(targets
    /// in that window), not O(targets in the app). Targets that hover anywhere are recomputed
    /// too (a view that left its window or hid must clear). Call after anything moves, hides or
    /// reflows views under a possibly still pointer. A refresh that an `onChange` starts (a hover
    /// that expands a stack) runs right after the current one.
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
            let (targets, moved) = index.candidates(in: current)
            // A target found in another window now: that window refreshes too (a view that moved
            // there under a still pointer).
            for other in moved where other !== current && !queue.contains(where: { $0 === other }) { queue.append(other) }
            for target in targets {
                if target.isHovering || target.viewWindow === current { target.update() }
            }
            queue.append(contentsOf: pending)
            pending.removeAll()
        }
    }

    /// A key-window change: every target is filed under its window again (a view that moved
    /// straight from one window to another is found), then `window` refreshes. O(all targets),
    /// once per key change.
    fileprivate static func keyChanged(_ window: NSWindow?) {
        index.placeAll()
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

/// `PointerHover`'s targets filed by window (cx-8w027.10 item c): a refresh reads one window's
/// targets, the targets without a window and the targets that hover now. A target is filed under
/// the window its view is in when the index last saw it: at a refresh that visits it, at its own
/// enter, exit or `refresh()`, and at every key-window change. A refresh files each visited target
/// again, so a view that left the window moves to `unplaced`, one that came in from `unplaced` is
/// filed under its window, and one found in another window refreshes that window too.
@MainActor
private final class TargetIndex {
    private struct Weak {
        weak var value: PointerHover?
    }

    private struct Bucket {
        weak var window: NSWindow?
        var targets: [ObjectIdentifier: Weak] = [:]
    }

    private var buckets: [ObjectIdentifier: Bucket] = [:]
    /// Targets whose view had no window when last seen.
    private var unplaced: [ObjectIdentifier: Weak] = [:]
    /// Targets that hover now (a handful).
    private var hovering: [ObjectIdentifier: Weak] = [:]
    private var nextOrder: UInt64 = 0

    func insert(_ target: PointerHover) {
        nextOrder &+= 1
        target.order = nextOrder
        target.indexedWindow = nil
        unplaced[ObjectIdentifier(target)] = Weak(value: target)
        place(target)
    }

    func noteHovering(_ target: PointerHover, _ hovers: Bool) {
        hovering[ObjectIdentifier(target)] = hovers ? Weak(value: target) : nil
    }

    /// Files `target` under the window its view is in now; returns that window when the target
    /// moved into it.
    @discardableResult
    func place(_ target: PointerHover) -> NSWindow? {
        let key = ObjectIdentifier(target)
        let window = target.viewWindow
        let now = window.map(ObjectIdentifier.init)
        let filed = now.map { buckets[$0]?.window === window && buckets[$0]?.targets[key] != nil } ?? (unplaced[key] != nil)
        guard now != target.indexedWindow || !filed else { return nil }
        if let old = target.indexedWindow {
            buckets[old]?.targets[key] = nil
            if buckets[old]?.targets.isEmpty == true { buckets[old] = nil }
        }
        unplaced[key] = nil
        target.indexedWindow = now
        guard let window, let now else {
            unplaced[key] = Weak(value: target)
            return nil
        }
        // A window identifier reused by a new window: the old window's targets go back to `unplaced`.
        if let bucket = buckets[now], bucket.window !== window { dropBucket(now) }
        if buckets[now] == nil { buckets[now] = Bucket(window: window) }
        buckets[now]?.targets[key] = Weak(value: target)
        return window
    }

    /// Every target filed under its window again; freed targets and closed windows drop out.
    func placeAll() {
        for (key, bucket) in buckets where bucket.window == nil { dropBucket(key) }
        let all = buckets.values.flatMap { $0.targets.values.compactMap(\.value) } + unplaced.values.compactMap(\.value)
        for (key, bucket) in buckets { buckets[key]?.targets = bucket.targets.filter { $0.value.value != nil } }
        unplaced = unplaced.filter { $0.value.value != nil }
        for target in all { place(target) }
    }

    /// The targets a refresh of `window` reads, in creation order with the hovering ones first
    /// (a hover that ends runs before one that starts), each filed again; and the other windows
    /// a visited target was found in. Freed targets drop out.
    func candidates(in window: NSWindow) -> (targets: [PointerHover], moved: [NSWindow]) {
        let key = ObjectIdentifier(window)
        if let bucket = buckets[key], bucket.window !== window { dropBucket(key) }
        var found: [ObjectIdentifier: PointerHover] = [:]
        for (id, entry) in buckets[key]?.targets ?? [:] {
            if let target = entry.value { found[id] = target } else { buckets[key]?.targets[id] = nil }
        }
        for (id, entry) in unplaced {
            if let target = entry.value { found[id] = target } else { unplaced[id] = nil }
        }
        for (id, entry) in hovering {
            if let target = entry.value { found[id] = target } else { hovering[id] = nil }
        }
        var moved: [NSWindow] = []
        for target in found.values {
            if let other = place(target), other !== window, !moved.contains(where: { $0 === other }) { moved.append(other) }
        }
        // One integer per target: a tuple compare goes through the runtime's tuple metadata on
        // every comparison, half of a Cmd-Tab's main-thread time with a few thousand targets.
        let targets = found.values.map { (key: ($0.isHovering ? 0 : 1 << 63) | $0.order, target: $0) }
            .sorted { $0.key < $1.key }.map(\.target)
        return (targets, moved)
    }

    /// Drops the bucket under `key` (its window closed, or a new window reuses the identifier):
    /// its live targets go back to `unplaced`, to be filed again where their views are.
    private func dropBucket(_ key: ObjectIdentifier) {
        guard let bucket = buckets.removeValue(forKey: key) else { return }
        for (id, entry) in bucket.targets {
            guard let target = entry.value else { continue }
            target.indexedWindow = nil
            unplaced[id] = entry
        }
    }
}
