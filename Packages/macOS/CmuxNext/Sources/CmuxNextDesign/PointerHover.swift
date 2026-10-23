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
/// A refresh costs what is under the pointer, not what exists: it reads the
/// targets whose views lie under the pointer (a walk down the window's view
/// tree along the point) and the few that hover now (perf-lead.md cause 6).
/// So a target hovers only where AppKit would deliver its clicks: inside its
/// own bounds and every ancestor's, with no hidden ancestor.
///
/// A view that moves to another window under a still pointer lights on that
/// window's next refresh (an enter or exit there, a geometry refresh, a key
/// change), not at once: no index of windows is kept to notice the move. An
/// owner that re-parents a view under the pointer (a fullscreen titlebar
/// accessory, a re-hosted toast) calls `refresh(in:)` for the new window.
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
    /// The view's identity in the index (the view may be gone by `deinit`).
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
        order = Self.index.insert(self, view: view)
        Self.installKeyObserversIfNeeded()
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let area { view?.removeTrackingArea(area) }
            Self.index.dropFreed(under: viewKey)
        }
    }

    // MARK: Events

    // AppKit sends a tracking area's owner `mouseEntered:` and `mouseExited:`.
    // This owner is not an NSResponder, so the selectors must be named: a bare
    // `@objc` exports `mouseEnteredWith:`, and the first enter raised
    // NSInvalidArgumentException in `_dispatchMouseEntered:` (cx-2mp6).
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

    /// The target's creation order (a refresh runs its targets in it), from `TargetIndex.insert`.
    private(set) var order: UInt64 = 0

    private func computeHovering() -> Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor, isHoverable(),
              let pointer = Self.pointer(in: window, requireKey: requiresKeyWindow) else { return false }
        let local = view.convert(pointer, from: nil)
        let rect = (region?(view) ?? view.bounds).intersection(view.visibleRect)
        guard !rect.isNull, rect.contains(local) else { return false }
        return Self.isTopmost(window, passThrough: passThroughWindows())
    }

    // MARK: The pointer

    #if DEBUG
    /// DEBUG (`debug.mouse`, tests): the pointer synthesized per window, in
    /// window coordinates (`point` nil: outside the window), and where the
    /// real mouse was then. A window with a synthesized pointer ignores the
    /// real one until the real mouse moves (the user takes over) or the
    /// window closes. `mouse` nil: pinned, the real mouse never takes over
    /// (a test on a host where other jobs move the real pointer).
    struct DebugPointer {
        var point: NSPoint?
        var mouse: NSPoint?
    }

    static var debugPointers: [ObjectIdentifier: DebugPointer] = [:]

    /// DEBUG: sets `window`'s synthesized pointer (nil: outside the window),
    /// then refreshes the window's hover (`refresh(in:)`).
    ///
    /// - Parameter followsRealMouse: true (`debug.mouse`): the real mouse
    ///   takes over once it moves. False (tests): the pointer holds until it
    ///   is set again or the window closes.
    public static func setDebugPointer(_ point: NSPoint?, in window: NSWindow, followsRealMouse: Bool = true) {
        debugPointers[ObjectIdentifier(window)] = DebugPointer(point: point, mouse: followsRealMouse ? NSEvent.mouseLocation : nil)
        installKeyObserversIfNeeded()
        refresh(in: window)
    }

    /// DEBUG: the synthesized pointer of `window` while it holds: `.some(nil)`
    /// is a pointer outside the window, nil is no synthesized pointer.
    static func debugPointer(in window: NSWindow) -> NSPoint?? {
        let key = ObjectIdentifier(window)
        guard let entry = debugPointers[key] else { return nil }
        if let mouse = entry.mouse, mouse != NSEvent.mouseLocation {
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

    /// Recomputes the hover in `window` from the pointer and the current frames: the targets
    /// whose views lie under the pointer and the targets that hover anywhere now (a view that
    /// moved away, hid or left its window must clear). It recomputes only those targets, and
    /// its walk reads the children of the views on the pointer's path (`TargetIndex`), not
    /// every target in the window: rows, tabs and buttons off the path cost nothing. A flat
    /// container's direct children are the path's fan-out, so an unvirtualized list costs its
    /// row count in frame reads (no hover recompute). Call after anything moves, hides or
    /// reflows views under a possibly still pointer. A refresh that an `onChange` starts (a
    /// hover that expands a stack) runs right after the current one.
    public static func refresh(in window: NSWindow?) { // perf-hot: 0.5ms cmd-tab (every enter, exit, geometry refresh and key-window change)
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
            // A window in deallocation has no pointer: only the targets that hover clear.
            let point = current.isBeingDeallocated ? nil : pointer(in: current)
            for target in index.candidates(in: current, at: point) { target.update() }
            queue.append(contentsOf: pending)
            pending.removeAll()
        }
    }

    /// Becoming or resigning key changes whether key-window targets hover.
    private static func installKeyObserversIfNeeded() {
        guard keyObserver == nil else { return }
        keyObserver = KeyWindowObserver()
    }
}
