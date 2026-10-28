public import AppKit
import CmuxNextDesign

/// Divider hit areas over Chromium pages.
///
/// A divider's hit area is wider than its line and reaches into the panes
/// next to it. A Chromium page is a child window above the parent, so it
/// would get the mouse there. Masking the page there (an occlusion hole)
/// took a band of the page away on each side of every divider. Instead,
/// while a page window takes the mouse (a page drawn in its own window, or
/// a layer-hosted page's input window), each hit area gets a small
/// transparent panel above the pages that takes the mouse and forwards it
/// to the parent window, where the divider view handles it as before. The
/// page draws edge to edge under it. A page attached as a view of its pane
/// (Chrome's model: `RenderWidgetHostViewCocoa` is a subview,
/// `content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`) needs
/// none: the divider views are above it in the same window, and
/// `WindowOverlayLayer` makes no catchers at all. So does every page of a
/// window whose pages draw in its view tree (``PageSurface/views``, the
/// Chromium Host): such a window never shows a catcher panel.
///
/// A content panel (`ContentChildPanel`: a remote page's popup reaching
/// past the page's edge) lies below these panels, so a catcher never covers
/// one: each area is cut around the popups' frames (``update(_:active:excluding:)``)
/// and the popup keeps its clicks and hover there.
///
/// Panels are `NSPanel`s at the overlay's level, so `WindowOverlayLayer`
/// keeps them above page windows with its other app panels. Lives here, not
/// in CmuxNextApp (code-quality.md SW14).
///
/// A panel is made the first time the pointer comes to its area (``pointerMoved(toScreen:)``, fed by the
/// window's pointer moves, the page windows' included), or at once for an area that appears under the
/// pointer, so a click there without a move still reaches the divider. A press that still finds no panel (no
/// move came first: the app was not active, or a flick) goes to the divider all the same (``intercept(_:)``).
/// A landed layout makes none: a new window's first turns made one NSPanel per divider hit area, 386 ms
/// (first-5s bench, 2026-10-28), for dividers the person mostly never touches. A panel once made follows its
/// area until the area goes. With no pointer moves to read (`lazy` false), every area gets its panel at once.
@MainActor
public final class DividerMouseCatchers {
    private unowned let window: NSWindow
    private var panels: [String: DividerMousePanel] = [:]
    /// Called with (divider id, hovered) for the divider's hover line.
    public var onHover: ((String, Bool) -> Void)?
    /// Panel frame changes and panels made since launch (`debug.layers`): each is a window
    /// server move, so a bench counts them over an action.
    public private(set) var panelUpdates = 0
    /// The pieces the last ``update(_:active:excluding:)`` wants covered; a piece without a panel gets one when
    /// the pointer comes to it.
    private var wanted: [Piece] = []
    /// Wanted pieces that have no panel yet, in wanted order: a pointer move tests only these rects.
    private var waiting: [Piece] = []
    /// Where the pointer is now, in screen coordinates (tests pass their own).
    private let pointerLocation: @MainActor () -> CGPoint
    /// Panels wait for the pointer (the window's pointer moves and presses come to ``pointerMoved(toScreen:)``
    /// and ``intercept(_:)``); false makes every area's panel at once.
    private let lazy: Bool
    /// The button of the press ``intercept(_:)`` sent to the window: its drags and its release follow it there.
    private var forwardedButton: Int?

    /// - Parameters:
    ///   - window: The window whose divider areas get panels.
    ///   - lazy: The caller feeds the window's pointer moves and presses; false when it has none to feed.
    ///   - pointerLocation: The pointer's screen point now; read once per update, for an area that appears
    ///     under a pointer that does not move.
    public init(window: NSWindow, lazy: Bool = true,
                pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) { // global-input-allow: read once per layout landing, outside any dispatch, for an area that appears under a still pointer
        self.window = window
        self.lazy = lazy
        self.pointerLocation = pointerLocation
    }

    /// Some wanted area has no panel yet: the window's pointer moves are worth reading.
    public var wantsPointer: Bool { !waiting.isEmpty }

    /// Some area is wanted, or a press sent on still holds the mouse: the window's presses, drags and releases are
    /// worth reading (``intercept(_:)``). A press can reach a page window over an area whose panel the same turn's
    /// queued move just made (a flick under load), so made panels count too. Presses are rare; drags cost one check.
    public var wantsPresses: Bool { !wanted.isEmpty || forwardedButton != nil }

    /// The wanted areas with no panel yet, in window coordinates (tests move the pointer into them).
    var waitingRects: [CGRect] { waiting.map(\.area.rect) }

    /// Window numbers of the panels shown: they pass divider hover through.
    public var windowNumbers: Set<Int> { Set(panels.values.filter { $0.isVisible }.map(\.windowNumber)) }

    /// How many panels show, counted with no allocation (a `cef.geometry` slice's end).
    public var shownCount: Int {
        var count = 0
        for panel in panels.values where panel.isVisible { count += 1 }
        return count
    }

    /// Frames of the panels shown, in window coordinates (`debug.layers`).
    public var framesInWindow: [String: CGRect] {
        panels.compactMapValues { $0.parent === window ? window.convertFromScreen($0.frame) : nil }
    }

    /// Shows one panel per area (window coordinates), or none when `active`
    /// is false (no page window takes the mouse) or the window's pages draw
    /// in its view tree (``PageSurface/views``). An area's part under a
    /// rect of `holes` (window coordinates: the content panels' frames) gets
    /// no panel, so the popup there keeps the mouse.
    public func update(_ areas: [LayoutMouseArea], active: Bool, excluding holes: [CGRect] = []) {
        let takesMouse = active && window.isVisible && PageSurface.of(window) == .childWindows
        let wanted = takesMouse ? Self.pieces(of: areas, excluding: holes) : []
        let keys = Set(wanted.map(\.key))
        for (key, panel) in panels where !keys.contains(key) {
            if panel.parent === window { window.removeChildWindow(panel) }
            panel.orderOut(nil)
            panels[key] = nil
        }
        self.wanted = wanted
        // An area that appears under the pointer gets its panel now: no move may come before the click.
        let pointer = lazy && wanted.contains(where: { panels[$0.key] == nil }) ? pointerLocation() : nil
        for piece in wanted {
            if lazy, panels[piece.key] == nil {
                guard let pointer, window.convertToScreen(piece.area.rect).contains(pointer) else { continue }
            }
            place(piece)
        }
        waiting = wanted.filter { panels[$0.key] == nil }
    }

    /// The pointer moved to `point` (screen coordinates) in the window or one of its page windows: the
    /// wanted area under it gets its panel, the first time only. Returns whether a panel was made.
    @discardableResult
    public func pointerMoved(toScreen point: CGPoint) -> Bool { // perf-hot: 5us input-tap (each pointer move while an area waits)
        guard !waiting.isEmpty else { return false }
        let point = window.convertPoint(fromScreen: point)
        guard let index = waiting.firstIndex(where: { $0.area.rect.contains(point) }) else { return false }
        place(waiting.remove(at: index))
        return true
    }

    /// A press, drag or release in the window or one of its page windows. A press on a page window inside a wanted
    /// area goes to the window, where the divider takes it, as the area's panel would have sent it, and the area
    /// gets its panel after; that press's drags and its release follow it there. Returns whether the event was
    /// sent on: the caller drops it then, so the page never sees it.
    public func intercept(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = Self.button(of: event)
            // Another button pressed during a forwarded press (a chord) leaves that press held and is not the divider's.
            if let held = forwardedButton, held != button { return false }
            // The same button pressed again: its last release never came here (a menu or a modal took it).
            forwardedButton = nil
            // A press on the window itself reaches the divider without help.
            guard !wanted.isEmpty, let source = event.window, source !== window else { return false }
            let point = window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
            guard let piece = wanted.first(where: { $0.area.rect.contains(point) }) else { return false }
            forwardedButton = button
            DividerMouseCatcherView.forward(event, at: point, to: window)
            // The press is on its way first; the panel (a window-server change) waits for no click.
            if let index = waiting.firstIndex(of: piece) { place(waiting.remove(at: index)) }
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let held = forwardedButton, held == Self.button(of: event), let source = event.window else { return false }
            if event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp { forwardedButton = nil }
            let point = source === window ? event.locationInWindow
                : window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
            DividerMouseCatcherView.forward(event, at: point, to: window)
            return true
        default:
            return false
        }
    }

    /// The button of a mouse event: left 0 and right 1 by its type, any other by its number.
    private static func button(of event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: 0
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: 1
        default: max(event.buttonNumber, 2)
        }
    }

    /// Makes `piece`'s panel if it has none, and puts it over the piece's area, above the window.
    private func place(_ piece: Piece) {
        if panels[piece.key] == nil { panelUpdates += 1 }
        let panel = panels[piece.key] ?? makePanel(id: piece.area.id)
        panels[piece.key] = panel
        panel.catcher.resizesColumns = piece.area.resizesColumns
        let frame = window.convertToScreen(piece.area.rect)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            panelUpdates += 1
        }
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
    }

    /// One catcher panel's area: `area` keeps its divider's id (hover reports it), `key` names the panel.
    nonisolated struct Piece: Equatable, Sendable {
        let key: String
        let area: LayoutMouseArea
    }

    /// `areas` cut around `holes`. An area no hole touches is one piece keyed by its id; a cut area's
    /// pieces are keyed `<id>#<n>`.
    nonisolated static func pieces(of areas: [LayoutMouseArea], excluding holes: [CGRect]) -> [Piece] {
        var result: [Piece] = []
        for area in areas {
            var rects = [area.rect]
            for hole in holes where hole.intersects(area.rect) {
                rects = rects.flatMap { subtract(hole, from: $0) }
            }
            if rects == [area.rect] {
                result.append(Piece(key: area.id, area: area))
                continue
            }
            for (index, rect) in rects.enumerated() {
                var piece = area
                piece.rect = rect
                result.append(Piece(key: "\(area.id)#\(index)", area: piece))
            }
        }
        return result
    }

    /// The parts of `rect` outside `hole`: up to four rects (the full-height sides, then the bands
    /// below and above the hole), none empty.
    nonisolated static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        let parts = [
            CGRect(x: rect.minX, y: rect.minY, width: cut.minX - rect.minX, height: rect.height),
            CGRect(x: cut.maxX, y: rect.minY, width: rect.maxX - cut.maxX, height: rect.height),
            CGRect(x: cut.minX, y: rect.minY, width: cut.width, height: cut.minY - rect.minY),
            CGRect(x: cut.minX, y: cut.maxY, width: cut.width, height: rect.maxY - cut.maxY),
        ]
        return parts.filter { $0.width > 0 && $0.height > 0 }
    }

    public func teardown() {
        update([], active: false)
        forwardedButton = nil
    }

    private func makePanel(id: String) -> DividerMousePanel {
        let panel = DividerMousePanel()
        panel.catcher.onHover = { [weak self] hovered in self?.onHover?(id, hovered) }
        return panel
    }
}

/// A transparent panel that takes the mouse over a divider's hit area.
final class DividerMousePanel: NSPanel {
    let catcher = DividerMouseCatcherView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Explicitly false: a clear window would otherwise pass clicks
        // through its transparent pixels.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        catcher.autoresizingMask = [.width, .height]
        contentView = catcher
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Forwards every mouse event to the parent window at the same screen
/// point: `NSWindow.sendEvent` hit-tests the parent's views, so the divider
/// view gets the press and, as the press's view, the drags and the release.
final class DividerMouseCatcherView: NSView {
    var resizesColumns = true {
        didSet { if resizesColumns != oldValue, isEntered { cursor.set() } }
    }
    var onHover: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // This panel is never key: track in the active app, not the key window, or it never sees the pointer.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeForHover, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor {
        if #available(macOS 15, *) { return resizesColumns ? .columnResize : .rowResize }
        return resizesColumns ? .resizeLeftRight : .resizeUpDown
    }

    /// Whether the pointer is over this catcher now: its panel shows, takes the mouse, and holds
    /// the pointer. Read on the turn after an enter, outside its dispatch. A seam for tests, which
    /// have no screen pointer.
    lazy var isPointerOver: () -> Bool = { [weak self] in
        guard let self, let panel = self.window, panel.isVisible, panel.alphaValue > 0, !panel.ignoresMouseEvents,
              !self.isHiddenOrHasHiddenAncestor else { return false } // visibility-walk-allow: a hit test of the pointer, read once on the turn after an enter
        // global-input-allow: next turn, outside dispatch; the pointer may have left before its exit is handled.
        return self.convert(self.bounds, to: nil).contains(panel.convertPoint(fromScreen: NSEvent.mouseLocation))
    }
    /// The cursor set queued after an enter, while it is pending (tests await it).
    private(set) var pendingCursorSet: Task<Void, Never>?
    /// Between this catcher's enter and its exit.
    private var isEntered = false

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) {
        isEntered = true
        cursor.set()
        // A focused page window holds key. When the pointer leaves it straight onto this panel's
        // part outside it (the sidebar's resize band reaches over the sidebar), AppKit puts the
        // arrow back for the key window later in this event's turn, and this panel, never key,
        // gets no cursor update or move after that. Set the cursor once more on the next turn,
        // only if no exit came and the panel still shows under the pointer (a panel parked,
        // hidden or moved meanwhile gets no exit). One-shot: nothing repeats or stays scheduled.
        pendingCursorSet?.cancel()
        pendingCursorSet = Task { @MainActor [weak self] in // main-hop-allow: AppKit resets the key window's arrow later in this enter's turn; the cursor set must run after that turn
            guard let self else { return }
            self.pendingCursorSet = nil
            guard !Task.isCancelled, self.isEntered, self.isPointerOver() else { return }
            self.cursor.set()
        }
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        isEntered = false
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) { forward(event) }
    // input-coalesce: native (a forward into the parent window, whose divider drag coalesces it, p04-input-031)
    override func mouseDragged(with event: NSEvent) { forward(event) } // local-monitor-allow: a forward to the parent window, order and count kept; the divider there coalesces its drag
    override func mouseUp(with event: NSEvent) { forward(event) }
    override func rightMouseDown(with event: NSEvent) { forward(event) }
    override func rightMouseUp(with event: NSEvent) { forward(event) }
    override func otherMouseDown(with event: NSEvent) { forward(event) }
    override func otherMouseUp(with event: NSEvent) { forward(event) }

    // The event's own screen point (`screenLocation`): the panel moves while a divider drags.
    // input-coalesce: native (a forward; the view under it coalesces its own scroll)
    override func scrollWheel(with event: NSEvent) { // local-monitor-allow: a forward to the view under the pointer in the parent window, order and count kept
        guard let parent = window?.parent, let content = parent.contentView else { return }
        let point = content.convert(parent.convertPoint(fromScreen: event.screenLocation), from: nil)
        content.hitTest(point)?.scrollWheel(with: event)
    }

    private func forward(_ event: NSEvent) {
        guard let parent = window?.parent else { return }
        Self.forward(event, at: parent.convertPoint(fromScreen: event.screenLocation), to: parent)
    }

    /// Sends `event` to `parent` at `point` (`parent`'s coordinates).
    static func forward(_ event: NSEvent, at point: CGPoint, to parent: NSWindow) {
        guard let forwarded = NSEvent.mouseEvent(
                  with: event.type, location: point,
                  modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: parent.windowNumber,
                  context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
              )
        else { return }
        parent.sendEvent(forwarded)
    }
}
