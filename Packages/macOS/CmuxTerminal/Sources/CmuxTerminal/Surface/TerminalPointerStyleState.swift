public import AppKit
internal import GhosttyKit

/// Main-actor AppKit projection of one complete terminal pointer intent.
@MainActor
public struct TerminalPointerStyleState {
    private var intent = TerminalPointerIntentState()
    private var resolvedShape = GHOSTTY_MOUSE_SHAPE_TEXT
    private var resolvedCursor = NSCursor.iBeam
    // Finite supported-shape vocabulary: factory cursors are allocated at most
    // once per shape per view, never once per callback or cursor-rect rebuild.
    private var cursorsByShape: [UInt32: NSCursor] = [:]

    /// Creates a projection with the normal terminal I-beam.
    public init() {}

    /// The already-resolved cursor for AppKit cursor rects.
    public var effectiveCursor: NSCursor { resolvedCursor }
    /// Whether cmux's link affordance is active.
    public var cmuxLinkHoverActive: Bool { intent.cmuxLinkHoverActive }
    /// Whether Ghostty's link affordance is active.
    public var ghosttyLinkHoverActive: Bool { intent.ghosttyLinkHoverActive }
    /// Whether the terminal owns keyboard focus.
    public var focused: Bool { intent.focused }

    /// Reduces a direct event and updates its AppKit projection.
    /// - Parameter event: A runtime, shape, focus, or hover transition.
    /// - Returns: Whether cursor rects need invalidation.
    @discardableResult
    public mutating func apply(_ event: TerminalPointerStyleEvent) -> Bool {
        let invalidated = intent.apply(event)
        resolveCursor()
        return invalidated
    }

    /// Replaces the read-only UI projection with the mailbox's complete state.
    /// - Parameter snapshot: Authoritative intent after all accepted callbacks.
    /// - Returns: Whether the effective cursor changed.
    @discardableResult
    public mutating func replaceIntent(_ snapshot: TerminalPointerIntentState) -> Bool {
        let changed = intent.effectiveShape != snapshot.effectiveShape
        intent = snapshot
        resolveCursor()
        return changed
    }

    private mutating func resolveCursor() {
        let shape = intent.effectiveShape
        guard shape != resolvedShape else { return }
        if let cached = cursorsByShape[shape.rawValue] {
            resolvedCursor = cached
        } else if let cursor = cursor(for: shape) {
            cursorsByShape[shape.rawValue] = cursor
            resolvedCursor = cursor
        }
        resolvedShape = shape
    }

    /// Maps a Ghostty CSS pointer shape to the closest public AppKit cursor.
    ///
    /// Shapes without a faithful public cursor on the running macOS version
    /// return `nil`; callers preserve the currently active pointer in that case.
    ///
    /// - Parameter shape: The shape emitted by libghostty.
    /// - Returns: The closest supported AppKit cursor, or `nil` when unmapped.
    func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return .arrow
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CELL,
             GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_ALIAS:
            return .dragLink
        case GHOSTTY_MOUSE_SHAPE_COPY:
            return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_MOVE,
             GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
             GHOSTTY_MOUSE_SHAPE_GRAB:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NO_DROP,
             GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            if #available(macOS 15.0, *) {
                return .columnResize
            }
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            if #available(macOS 15.0, *) {
                return .rowResize
            }
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            if #available(macOS 15.0, *) {
                return .rowResize(directions: .up)
            }
            return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            if #available(macOS 15.0, *) {
                return .columnResize(directions: .right)
            }
            return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            if #available(macOS 15.0, *) {
                return .rowResize(directions: .down)
            }
            return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            if #available(macOS 15.0, *) {
                return .columnResize(directions: .left)
            }
            return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topRight, directions: .outward)
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topRight, directions: .all)
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_NW_RESIZE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topLeft, directions: .outward)
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topLeft, directions: .all)
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_SE_RESIZE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .bottomRight, directions: .outward)
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_SW_RESIZE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .bottomLeft, directions: .outward)
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_ZOOM_IN:
            if #available(macOS 15.0, *) {
                return .zoomIn
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_ZOOM_OUT:
            if #available(macOS 15.0, *) {
                return .zoomOut
            }
            return nil
        case GHOSTTY_MOUSE_SHAPE_HELP,
             GHOSTTY_MOUSE_SHAPE_PROGRESS,
             GHOSTTY_MOUSE_SHAPE_WAIT:
            return nil
        default:
            return nil
        }
    }
}
