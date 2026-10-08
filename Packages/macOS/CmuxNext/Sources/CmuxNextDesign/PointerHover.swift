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
        Self.targets.append(WeakTarget(self))
        Self.installKeyObserversIfNeeded()
    }

    isolated deinit {
        if let area { view?.removeTrackingArea(area) }
    }

    /// The view this target hovers.
    public var hoveredView: NSView? { view }

    // MARK: Events

    // AppKit sends a tracking area's owner `mouseEntered:` and `mouseExited:`.
    // This owner is not an NSResponder, so the selectors must be named: a bare
    // `@objc` exports `mouseEnteredWith:`, and the first enter raised
    // NSInvalidArgumentException in `_dispatchMouseEntered:` (cx-2mp6).
    @objc(mouseEntered:) public func mouseEntered(with event: NSEvent) { Self.refresh(in: view?.window) }
    @objc(mouseExited:) public func mouseExited(with event: NSEvent) { Self.refresh(in: view?.window) }

    /// Recomputes this target only (its eligibility changed).
    public func refresh() { update() }

    private func update() {
        let hovering = computeHovering()
        guard hovering != isHovering else { return }
        isHovering = hovering
        onChange?(hovering)
    }

    private func computeHovering() -> Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor, isHoverable(),
              let pointer = Self.pointer(in: window, requireKey: requiresKeyWindow) else { return false }
        let local = view.convert(pointer, from: nil)
        let rect = (region?(view) ?? view.bounds).intersection(view.visibleRect)
        guard !rect.isNull, rect.contains(local) else { return false }
        return Self.isTopmost(window)
    }

    // MARK: The pointer

    #if DEBUG
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

    /// DEBUG: `window` reads the real pointer again (tests restore with it).
    public static func clearDebugPointer(in window: NSWindow) {
        debugPointers[ObjectIdentifier(window)] = nil
        refresh(in: window)
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

    private struct WeakTarget {
        weak var value: PointerHover?
        init(_ value: PointerHover) { self.value = value }
    }

    private static var targets: [WeakTarget] = []
    private static var refreshing = false
    private static var pending: [NSWindow] = []
    private static var keyObserver: KeyWindowObserver?

    /// Recomputes every target in `window` (and clears targets whose view
    /// left its window) from the pointer and the current frames. Call after
    /// anything moves, hides or reflows views under a possibly still
    /// pointer. A refresh that an `onChange` starts (a hover that expands a
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
            targets.removeAll { $0.value == nil }
            for target in targets.compactMap(\.value) {
                let targetWindow = target.view?.window
                if targetWindow === current || (targetWindow == nil && target.isHovering) { target.update() }
            }
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

/// Key-window changes refresh that window's hover (`PointerHover`).
@MainActor
private final class KeyWindowObserver: NSObject {
    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: name, object: nil)
        }
        #if DEBUG
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        #endif
    }

    #if DEBUG
    /// A closed window's synthesized pointer must not pass to a new window
    /// that reuses its address.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        PointerHover.debugPointers[ObjectIdentifier(window)] = nil
    }
    #endif

    @objc private func keyWindowChanged(_ notification: Notification) {
        PointerHover.refresh(in: notification.object as? NSWindow)
    }
}
