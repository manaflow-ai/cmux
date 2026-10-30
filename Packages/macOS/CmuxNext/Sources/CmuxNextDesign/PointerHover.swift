public import AppKit
import CmuxNextWakeups

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
/// - every key-window change, every activation or deactivation of cmux, and
///   every `debug.mouse` pointer (DEBUG).
///
/// Hover follows the tracking area's scope: an `.activeForHover` target does
/// not hover while another app is active (its area hears no exit then, so
/// cmux resigning active clears it); a `hoversWhileInactive` target (a panel
/// that floats over another app) does.
///
/// The layout's divider hover (`ScreenDividers`) reads the same pointer: the enter or exit's own
/// point while one is handled, the window's cursor sample otherwise.
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
    /// The target hovers while another app is active too (a panel over System Settings).
    public let hoversWhileInactive: Bool

    private weak var view: NSView?
    private var area: NSTrackingArea?
    /// The view's identifier, for the index's entry (read in `deinit`, after the view may be gone).
    private let viewKey: ObjectIdentifier

    /// - Parameter requiresKeyWindow: false for window chrome (hover shows in
    ///   a background window of the active app, as in the sidebar), true for sheets.
    /// - Parameter hoversWhileInactive: true only for a view in a panel that
    ///   floats over another app with cmux in the background.
    public init(_ view: NSView, requiresKeyWindow: Bool = false, hoversWhileInactive: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.view = view
        viewKey = ObjectIdentifier(view)
        self.requiresKeyWindow = requiresKeyWindow
        self.hoversWhileInactive = hoversWhileInactive
        self.onChange = onChange
        super.init()
        // `.inVisibleRect` follows the view's visible rect, so the area never
        // needs replacing; the view's own `updateTrackingAreas` leaves it alone
        // (it removes only areas it owns).
        // wakeup-allow: bounded only a hoversWhileInactive target, in a panel that floats over another app, tracks while inactive
        let scope: NSTrackingArea.Options = requiresKeyWindow ? .activeInKeyWindow : hoversWhileInactive ? .activeAlways : .activeForHover
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, scope, .inVisibleRect], owner: self)
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
    // The target's own event refreshes the window its view is in now, and the window's targets
    // hover from the event's own point, as Chromium's `ui/views/widget/root_view.cc` hit-tests a
    // move's `event.location()`.
    @objc(mouseEntered:) public func mouseEntered(with event: NSEvent) {
        Self.refresh(in: view?.window, at: event)
    }
    @objc(mouseExited:) public func mouseExited(with event: NSEvent) {
        Self.refresh(in: view?.window, at: event)
    }

    /// Recomputes this target only (its eligibility changed).
    public func refresh() {
        update(at: nil)
    }

    private func update(at event: NSEvent?) {
        let hovering = computeHovering(at: event)
        guard hovering != isHovering else { return }
        isHovering = hovering
        Self.index.noteHovering(self, hovering)
        onChange?(hovering)
    }

    /// The target's creation order (a refresh runs its targets in it).
    var order: UInt64 = 0
    /// The view the target follows (the index matches it against the views under the pointer).
    var hoverView: NSView? { view }
    /// The view's window; nil while that window deallocates (its teardown moves the view out, and
    /// a weak reference to it aborts the runtime: "Cannot form weak reference to instance").
    var viewWindow: NSWindow? {
        guard let window = view?.window, !window.isBeingDeallocated else { return nil }
        return window
    }

    private func computeHovering(at event: NSEvent?) -> Bool {
        // visibility-walk-allow: the hover hit test: a view hidden under the pointer must not hover (AppKit's own
        // hit test skips hidden views the same way)
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor, isHoverable(),
              let pointer = Self.pointer(in: window, requireKey: requiresKeyWindow, event: event, whileInactive: hoversWhileInactive) else { return false }
        let local = view.convert(pointer, from: nil)
        let rect = (region?(view) ?? view.bounds).intersection(view.visibleRect)
        guard !rect.isNull, rect.contains(local) else { return false }
        return Self.isTopmost(window, at: pointer, passThrough: passThroughWindows())
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
        // global-input-allow: DEBUG debug.mouse, no event; the real cursor now, to see the user take over later.
        debugPointers[ObjectIdentifier(window)] = DebugPointer(point: point, mouse: NSEvent.mouseLocation)
        installKeyObserversIfNeeded()
        keyObserver?.forgetPointer(whenClosing: window)
        refresh(in: window)
    }

    /// DEBUG: the synthesized pointer of `window` while it holds: `.some(nil)`
    /// is a pointer outside the window, nil is no synthesized pointer.
    static func debugPointer(in window: NSWindow) -> NSPoint?? {
        let key = ObjectIdentifier(window)
        guard let entry = debugPointers[key] else { return nil }
        // global-input-allow: DEBUG debug.mouse; a real cursor move with no event in this app still hands back the pointer.
        guard entry.mouse == NSEvent.mouseLocation else {
            // The real mouse moved since: the user's pointer counts again.
            debugPointers[key] = nil
            return nil
        }
        return .some(entry.point)
    }

    #endif

    /// The pointer in `window`'s coordinates; nil when the window is not
    /// shown (or, with `requireKey`, not key), or while another app is active
    /// (`appShowsHover`). `debug.mouse`'s synthesized pointer wins in DEBUG builds.
    public static func pointer(in window: NSWindow, requireKey: Bool = false) -> NSPoint? {
        pointer(in: window, requireKey: requireKey, event: nil)
    }

    /// As `pointer(in:requireKey:)`, from `event`'s point while its window is the one asked about:
    /// the handler of an enter or exit passes its event. Outside an event (a layout pass, a scroll,
    /// a hide under a still pointer) there is none, and the window's own cursor sample is read, as
    /// Chromium's `Widget::SynthesizeMouseMoveEvent` replays the last mouse location after a layout
    /// change. `whileInactive` reads it while another app is active too (a panel over that app).
    public static func pointer(in window: NSWindow, requireKey: Bool, event: NSEvent?, whileInactive: Bool = false) -> NSPoint? {
        #if DEBUG
        if let synthetic = debugPointer(in: window) { return synthetic }
        #endif
        guard window.isVisible, !requireKey || window.isKeyWindow, whileInactive || appShowsHover else { return nil }
        if let event, event.window === window { return event.locationInWindow }
        // global-input-allow: no event (a layout, scroll or hide under a still pointer); the window's own cursor sample.
        return window.mouseLocationOutsideOfEventStream
    }

    /// The topmost window that takes the mouse under the real pointer is
    /// `window` or one of `passThrough` (no other window or panel covers the
    /// point). A window server round trip: ask only when a view is under the
    /// pointer.
    public static func isTopmost(_ window: NSWindow, passThrough: Set<Int> = []) -> Bool {
        // global-input-allow: no event at hand; the window's own cursor sample, as `pointer(in:requireKey:)` reads.
        return isTopmost(window, at: window.mouseLocationOutsideOfEventStream, passThrough: passThrough)
    }

    /// As `isTopmost(_:passThrough:)` at `point` (`window`'s coordinates), the same sample the
    /// hover test read, so both answer for one pointer.
    public static func isTopmost(_ window: NSWindow, at point: NSPoint, passThrough: Set<Int> = []) -> Bool {
        #if DEBUG
        if debugPointer(in: window) != nil { return true }
        #endif
        let top = NSWindow.windowNumber(at: window.convertPoint(toScreen: point), belowWindowWithWindowNumber: 0)
        return top == window.windowNumber || passThrough.contains(top)
    }

    // MARK: The owner

    private static let index = PointerHoverTargetIndex()
    private static var refreshing = false
    private static var pending: [NSWindow] = []
    private static var keyObserver: KeyWindowObserver?

    /// Recomputes `window`'s hover from the pointer and the current frames: the targets that
    /// hover now (anywhere: a view that left its window or hid must clear), then the targets whose
    /// views are under the pointer in `window` (`PointerHoverTargetIndex.candidates(in:at:)`).
    /// O(hovering + the views on the pointer's path), never O(targets): a sidebar layout pass
    /// calls it, and a scan of every target there made each layout pass cost every view in the
    /// app (the 2026-10-30 full-suite hang). Call after anything moves, hides or reflows views
    /// under a possibly still pointer. A refresh that an `onChange` starts (a hover that expands
    /// a stack) runs right after the current one.
    public static func refresh(in window: NSWindow?) {
        refresh(in: window, at: nil)
    }

    /// As `refresh(in:)`; `event` is the enter or exit that started it, read for its window.
    private static func refresh(in window: NSWindow?, at event: NSEvent?) {
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
            for target in index.candidates(in: current, at: event) { target.update(at: event) }
            queue.append(contentsOf: pending)
            pending.removeAll()
        }
    }

    /// A key-window change refreshes that window (a key-window target under the pointer starts or
    /// ends; the hovering ones elsewhere are recomputed with it).
    private static func keyChanged(_ window: NSWindow?) {
        refresh(in: window)
    }

    /// cmux activated or resigned active: the targets that hover now are recomputed (a deactivation
    /// clears every `.activeForHover` one, which hears no exit while another app is active), then the
    /// key window (an activation hovers what is under the pointer there).
    private static func activityChanged(_ keyWindow: NSWindow?) {
        for window in index.hoveringWindows() { refresh(in: window) }
        refresh(in: keyWindow)
    }

    /// Whether `.activeForHover` hover shows now: cmux is the active app (as of its last activity
    /// notice), or the launch never activates it (`CMUX_NEXT_NO_ACTIVATE`).
    public static var appShowsHover: Bool {
        WindowPlacement.noActivate || keyObserver?.isAppActive != false
    }

    /// Calls `clear` in the turn cmux resigns active, for a hover owner that tracks its own enter and
    /// exit with an `.activeForHover` area: that area hears no exit while another app is active. Keep
    /// the watch while the hover shows and drop it when the hover ends. Nil in a launch that never
    /// activates (its areas track always).
    public static func clearOnDeactivation(_ clear: @escaping @MainActor () -> Void) -> HoverDeactivationWatch? {
        guard !WindowPlacement.noActivate else { return nil }
        installKeyObserversIfNeeded()
        return keyObserver?.watchDeactivation(clear)
    }

    /// Observes key-window and activity changes on `events`, replacing the observer installed before;
    /// nil drops it, and the next target installs the app's own (tests pass their own center).
    static func observe(_ events: AppEvents?, keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow }) {
        keyObserver = events.map { events in
            KeyWindowObserver(events: events, keyWindow: keyWindow, changed: { keyChanged($0) }, activityChanged: { activityChanged($0) })
        }
    }

    /// Becoming or resigning key changes whether key-window targets hover; activating or resigning
    /// active changes whether `.activeForHover` targets do.
    private static func installKeyObserversIfNeeded() {
        guard keyObserver == nil else { return }
        observe(AppEvents(center: .default))
    }
}
