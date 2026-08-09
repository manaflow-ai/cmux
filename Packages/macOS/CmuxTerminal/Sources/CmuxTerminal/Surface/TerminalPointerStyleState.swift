public import AppKit
public import GhosttyKit

/// Resolves Ghostty and cmux pointer intent for one terminal surface.
///
/// The state keeps OSC 22 intent pane-local, temporarily presents the normal
/// terminal pointer while the pane is unfocused, and gives cmux link hover a
/// deterministic override without using the process-wide ``NSCursor`` stack.
@MainActor
public struct TerminalPointerStyleState {
    private var ghosttyCursor: NSCursor = .iBeam
    private var isFocused = false
    private var isCmuxLinkHoverActive = false

    /// Creates pointer state with the normal terminal I-beam.
    public init() {}

    /// The cursor AppKit should present for the current surface state.
    public var effectiveCursor: NSCursor {
        guard isFocused else { return .iBeam }
        return isCmuxLinkHoverActive ? .pointingHand : ghosttyCursor
    }

    /// Whether the focused surface is currently showing the cmux link override.
    public var cmuxLinkHoverActive: Bool { isCmuxLinkHoverActive }

    /// Applies one state transition and reports whether the effective cursor changed.
    ///
    /// Unsupported Ghostty shapes are ignored so an unknown or unavailable
    /// cursor never replaces the current pointer with an unrelated fallback.
    ///
    /// - Parameter event: The Ghostty, focus, cmux-hover, or reset transition.
    /// - Returns: `true` when AppKit cursor rects need invalidation.
    @discardableResult
    public mutating func apply(_ event: TerminalPointerStyleEvent) -> Bool {
        switch event {
        case .ghosttyShape(let shape):
            guard let cursor = cursor(for: shape) else { return false }
            let previousCursor = effectiveCursor
            ghosttyCursor = cursor
            return !cursorsEqual(previousCursor, effectiveCursor)

        case .focusChanged(let focused):
            guard isFocused != focused else { return false }
            let previousCursor = effectiveCursor
            isFocused = focused
            if !focused {
                isCmuxLinkHoverActive = false
            }
            return !cursorsEqual(previousCursor, effectiveCursor)

        case .cmuxLinkHoverChanged(let active):
            let nextActive = isFocused && active
            guard isCmuxLinkHoverActive != nextActive else { return false }
            let previousCursor = effectiveCursor
            isCmuxLinkHoverActive = nextActive
            return !cursorsEqual(previousCursor, effectiveCursor)

        case .reset:
            let previousCursor = effectiveCursor
            ghosttyCursor = .iBeam
            isCmuxLinkHoverActive = false
            return !cursorsEqual(previousCursor, effectiveCursor)
        }
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

    private func cursorsEqual(_ lhs: NSCursor, _ rhs: NSCursor) -> Bool {
        lhs === rhs || lhs.isEqual(rhs)
    }
}
