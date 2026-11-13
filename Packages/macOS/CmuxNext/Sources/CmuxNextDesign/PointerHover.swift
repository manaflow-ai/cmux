public import AppKit
import CmuxNextCompat

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
/// - every key-window change that can come with a new window order (`KeyWindowObserver`), and
///   every `debug.mouse` pointer (DEBUG).
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
        /// The tracking areas the synthesized pointer is inside (`SyntheticPointer`).
        var inside: [ObjectIdentifier: NSTrackingArea] = [:]
    }

    static var debugPointers: [ObjectIdentifier: DebugPointer] = [:]

    /// DEBUG: sets `window`'s synthesized pointer (nil: outside the window),
    /// then recomputes every target in the window.
    public static func setDebugPointer(_ point: NSPoint?, in window: NSWindow) {
        setDebugPointer(point, inside: debugInside(in: window), in: window)
    }

    /// DEBUG: sets `window`'s synthesized pointer and the tracking areas it is inside now (`SyntheticPointer`).
    static func setDebugPointer(_ point: NSPoint?, inside: [ObjectIdentifier: NSTrackingArea], in window: NSWindow) {
        debugPointers[ObjectIdentifier(window)] = DebugPointer(point: point, mouse: NSEvent.mouseLocation, inside: inside)
        installKeyObserversIfNeeded()
        refresh(in: window)
    }

    /// DEBUG: the tracking areas `window`'s synthesized pointer is inside (`SyntheticPointer`).
    static func debugInside(in window: NSWindow) -> [ObjectIdentifier: NSTrackingArea] {
        debugPointers[ObjectIdentifier(window)]?.inside ?? [:]
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
        let mouse = NSEvent.mouseLocation
        // A window clear under the pointer (a hover card's band) passes it to the window below.
        let top = topmostWindow(passes: { number in
            (NSApp.window(withWindowNumber: number) as? any PointerPassThroughWindow)?.passesPointer(atScreen: mouse) == true
        }, below: { NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: $0) })
        return top == window.windowNumber || passThrough.contains(top)
    }

    /// The front window under the pointer that keeps it: from the front, every window that
    /// `passes` the pointer is looked through to the one `below` it (0: none).
    static func topmostWindow(passes: (Int) -> Bool, below: (Int) -> Int) -> Int {
        var top = below(0)
        // A handful of stacked hover windows at most; the bound only stops a cycle.
        for _ in 0..<8 where top != 0 && passes(top) { top = below(top) }
        return top
    }

    // MARK: The owner

    private static let index = TargetIndex()
    private static var refreshing = false
    private static var pending: [NSWindow] = []
    /// The process's one observer of key-window changes (tests read what it knows).
    static private(set) var keyObserver: KeyWindowObserver?

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

    /// `window` became or resigned key: its key-window targets start or end (the other targets do
    /// not read the key). O(key-window targets), the buttons of a sheet.
    fileprivate static func keyChanged(in window: NSWindow) {
        for target in index.keyTargets(in: window) { target.update() }
    }

    /// Becoming or resigning key changes whether key-window targets hover, and a key change to
    /// another window can cover the pointer.
    private static func installKeyObserversIfNeeded() {
        guard keyObserver == nil else { return }
        keyObserver = KeyWindowObserver()
    }

    /// PROBE, never merges: how the key notices came since the last reset (`KeyWindowObserver.probe`).
    public static func keyProbe(reset: Bool) -> [String: Int] {
        let counts = keyObserver?.probe ?? [:]
        if reset { keyObserver?.probe = [:] }
        return counts
    }
}

/// What a key-window change does to hover (`PointerHover`).
///
/// A window that becomes or resigns key recomputes its key-window targets at once. The other
/// targets do not read the key: for them a key change matters only as a sign that the window
/// order changed (another window came to the front over a still pointer, and no exit arrives).
/// So the resign and the become of one key change are read together:
///
/// - The key moved inside one window, between it and a Chromium page window of it (`home(of:)`):
///   nothing is recomputed. A page window is the content of a pane of its window, above it before
///   and after, so such a change covers and uncovers nothing under the pointer. A workspace switch
///   between two browser tabs makes two such changes, 4 notices, and each notice used to ask the
///   window server for the topmost window at the pointer once for each target under it (a
///   synchronous round trip; 39 main-thread samples of a 10 switch recording). A panel, a sheet or
///   a popup of the window is not inside it: it can show over the pointer as it takes the key.
/// - The key moved to another window, or to or from a page window whose window is not known:
///   both windows are refreshed, as each notice did before.
/// - A window resigned and no window became key by the end of that pass of the run loop (another
///   app came to the front): that window is refreshed then, once, in that pass. A become in a
///   later pass refreshes its window as before.
///
/// Chromium does the same job with one synthesized mouse move after a change
/// (`Widget::SynthesizeMouseMoveEvent`), not one hit test for each view at each notice.
///
/// The notices arrive through `MainActorObservation` on the main queue, never a selector: AppKit
/// may post these off the main thread, and a selector into this main-actor class trapped there
/// (#18771). A post on the main thread runs the handler inline, so key changes and closes keep
/// their synchronous order.
@MainActor
final class KeyWindowObserver {
    /// A Chromium page window and the window it was a child of, both weak.
    private struct PageHome {
        weak var page: NSWindow?
        weak var window: NSWindow?
    }

    private var observations: [MainActorObservation] = []
    /// The window that resigned key, while no window became key after it.
    private weak var resigned: NSWindow?
    /// `resigned`'s home when it resigned (`home(of:)`).
    private weak var resignedHome: NSWindow?
    /// The end-of-pass read of `resigned` is queued.
    private var settles = false
    /// The window each Chromium page window was a child of when a key change last saw it with a
    /// parent, by the page window's identifier. It keeps no window alive, a window that closes
    /// leaves it, and each key change that sees the page with a parent writes the entry again.
    private var homes: [ObjectIdentifier: PageHome] = [:]
    /// PROBE, never merges: counts of the key notices by how they came.
    var probe: [String: Int] = [:]

    private func note(_ name: String) { probe[name, default: 0] += 1 }

    fileprivate init() {
        let window: @MainActor (Notification) -> NSWindow? = { $0.object as? NSWindow }
        observations.append(MainActorObservation(NSWindow.didResignKeyNotification, read: window) { [weak self] in
            self?.resign($0)
        })
        observations.append(MainActorObservation(NSWindow.didBecomeKeyNotification, read: window) { [weak self] in
            self?.become($0)
        })
        observations.append(MainActorObservation(NSWindow.willCloseNotification, read: window) { [weak self] in
            guard let closed = $0 else { return }
            self?.closed(closed)
            #if DEBUG || CMUX_BENCH_HOOKS
            // A closed window's synthesized pointer must not pass to a new window
            // that reuses its address.
            PointerHover.debugPointers[ObjectIdentifier(closed)] = nil
            #endif
        })
    }

    /// Where the key goes is not known yet: the become of this change posts after the resign, in
    /// this pass, or no window of the app takes the key.
    private func resign(_ window: NSWindow?) {
        guard let window else { return }
        note("resign")
        if resigned != nil { note("resign_after_resign") }
        PointerHover.keyChanged(in: window)
        // A second resign with no become between them: the first window's key left the app's windows.
        if let earlier = resigned, earlier !== window { PointerHover.refresh(in: earlier) }
        resigned = window
        resignedHome = home(of: window)
        guard !settles else { return }
        settles = true
        // A block of the run loop, not a timer and not a job of the main queue: it runs in the
        // pass that the notice is in (the pass that starts now, when the notice came between two).
        MainRunLoopBlock.perform { [weak self] in self?.settle() }
    }

    private func become(_ window: NSWindow?) {
        let (old, oldHome) = (resigned, resignedHome)
        (resigned, resignedHome) = (nil, nil)
        guard let window else { return }
        note("become")
        note(old == nil ? "become_alone" : "pair_in_one_pass")
        PointerHover.keyChanged(in: window)
        let newHome = home(of: window)
        if let old {
            if let oldHome, oldHome === newHome {
                note(newHome === window ? "family_to_window" : "family_to_page")
                return
            }
            note("pair_recomputed")
            PointerHover.refresh(in: old)
        }
        PointerHover.refresh(in: window)
    }

    /// The window `window` is a part of, for the pointer: itself, or for a Chromium page window
    /// (`CefNSWindow`) the window it is the content of. That is its parent; a page with no parent
    /// (a page that leaves at a workspace switch is ordered out, which takes it from its parent)
    /// is the content of the window a key change last saw it in (`homes`). Nil: a page window
    /// that no key change saw with a parent. The caller then recomputes the hover; nothing is
    /// guessed from the main window.
    private func home(of window: NSWindow) -> NSWindow? {
        guard let pageClass = NSClassFromString("CefNSWindow"), window.isKind(of: pageClass) else { return window }
        let key = ObjectIdentifier(window)
        guard var current = window.parent else { return knownHome(of: window) }
        // A page in a page at most; the bound only stops a cycle.
        for _ in 0..<4 {
            guard current.isKind(of: pageClass) else {
                if homes.count > 32 { homes = homes.filter { $0.value.page != nil && $0.value.window != nil } }
                homes[key] = PageHome(page: window, window: current)
                return current
            }
            guard let parent = current.parent else { break }
            current = parent
        }
        homes[key] = nil
        return nil
    }

    /// The window `page` was a child of when a key change last saw it with a parent, while both
    /// are open.
    func knownHome(of page: NSWindow) -> NSWindow? {
        guard let entry = homes[ObjectIdentifier(page)] else { return nil }
        // The identifier of a freed window can come again with a new window.
        guard entry.page === page, let window = entry.window else {
            homes[ObjectIdentifier(page)] = nil
            return nil
        }
        return window
    }

    /// `window` closes: as a page it leaves `homes`, and so do the pages that were its.
    private func closed(_ window: NSWindow) {
        homes[ObjectIdentifier(window)] = nil
        homes = homes.filter { $0.value.window !== window }
    }

    /// The pass that had a resign ends: with no become since, the key left the app's windows.
    private func settle() {
        settles = false
        guard let window = resigned else { return }
        note("resign_alone")
        (resigned, resignedHome) = (nil, nil)
        PointerHover.refresh(in: window)
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
    /// Targets that hover only in the key window (the buttons of a sheet: a handful).
    private var keyed: [ObjectIdentifier: Weak] = [:]
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
        if target.requiresKeyWindow { keyed[ObjectIdentifier(target)] = Weak(value: target) }
        if byView.count >= sweepAt { sweep() }
    }

    /// A target is freed (its `deinit`, on the main thread): its entries drop out.
    func remove(_ target: ObjectIdentifier, view: ObjectIdentifier) {
        hovering[target] = nil
        keyed[target] = nil
        guard let entries = byView[view] else { return }
        let live = entries.filter { $0.value != nil }
        byView[view] = live.isEmpty ? nil : live
    }

    func noteHovering(_ target: PointerHover, _ hovers: Bool) {
        hovering[ObjectIdentifier(target)] = hovers ? Weak(value: target) : nil
    }

    /// The key-window targets whose view is in `window` now, in creation order: a key change of
    /// `window` reads them and no other target.
    func keyTargets(in window: NSWindow) -> [PointerHover] {
        var found: [PointerHover] = []
        for (id, entry) in keyed {
            guard let target = entry.value else {
                keyed[id] = nil
                continue
            }
            if target.view?.window === window { found.append(target) }
        }
        return found.sorted { $0.order < $1.order }
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
