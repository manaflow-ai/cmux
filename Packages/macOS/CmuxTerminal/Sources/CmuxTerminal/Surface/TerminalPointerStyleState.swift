public import AppKit
internal import Foundation
public import GhosttyKit

/// Resolves Ghostty and cmux pointer intent for one terminal surface.
///
/// The state keeps OSC 22 intent pane-local, temporarily presents the normal
/// terminal pointer while the pane is unfocused, and gives cmux link hover a
/// deterministic override without using the process-wide ``NSCursor`` stack.
@MainActor
public struct TerminalPointerStyleState {
    private var ghosttyCursor: NSCursor = .iBeam
    /// Semantic identity for deduplicating factory cursors without image reads.
    private var ghosttyShape: ghostty_action_mouse_shape_e?
    /// The last supported non-pointer shape, used to restore the base cursor
    /// after Ghostty's temporary OSC 8 hyperlink pointer.
    private var lastNonPointerCursor: NSCursor = .iBeam
    private var lastNonPointerShape: ghostty_action_mouse_shape_e?
    private var activeRuntimeLifetimeId: UUID?
    private var isFocused = false
    private var isCmuxLinkHoverActive = false
    private var isGhosttyLinkHoverActive = false
    /// An unsupported base shape observed after a temporary pointer is held
    /// until Ghostty's empty link action confirms that the hyperlink ended.
    private var pendingUnsupportedBaseAfterPointer = false

    /// Creates pointer state with the normal terminal I-beam.
    public init() {}

    /// The cursor AppKit should present for the current surface state.
    public var effectiveCursor: NSCursor {
        if isCmuxLinkHoverActive { return .pointingHand }
        guard isFocused else { return .iBeam }
        if isGhosttyLinkHoverActive {
            return .pointingHand
        }
        return ghosttyCursor
    }

    /// Whether this surface is currently showing the cmux link override.
    public var cmuxLinkHoverActive: Bool { isCmuxLinkHoverActive }

    /// Whether Ghostty's transient hyperlink pointer is active.
    public var ghosttyLinkHoverActive: Bool { isGhosttyLinkHoverActive }

    /// Whether the terminal surface currently owns keyboard focus.
    public var focused: Bool { isFocused }

    /// Applies one state transition and reports whether the effective cursor changed.
    ///
    /// Unsupported Ghostty shapes are ignored so an unknown or unavailable
    /// cursor never replaces the current pointer with an unrelated fallback.
    ///
    /// - Parameter event: The runtime, Ghostty, focus, or cmux-hover transition.
    /// - Returns: `true` when AppKit cursor rects need invalidation.
    @discardableResult
    public mutating func apply(_ event: TerminalPointerStyleEvent) -> Bool {
        switch event {
        case .runtimeActivated(let runtimeLifetimeId):
            let shouldInvalidate = (
                ghosttyShape != nil ||
                isCmuxLinkHoverActive ||
                isGhosttyLinkHoverActive
            )
            activeRuntimeLifetimeId = runtimeLifetimeId
            ghosttyCursor = .iBeam
            ghosttyShape = nil
            lastNonPointerCursor = .iBeam
            lastNonPointerShape = nil
            isCmuxLinkHoverActive = false
            isGhosttyLinkHoverActive = false
            pendingUnsupportedBaseAfterPointer = false
            return shouldInvalidate

        case .runtimeReset(let runtimeLifetimeId):
            guard activeRuntimeLifetimeId == runtimeLifetimeId else { return false }
            let shouldInvalidate = (
                ghosttyShape != nil ||
                isCmuxLinkHoverActive ||
                isGhosttyLinkHoverActive
            )
            ghosttyCursor = .iBeam
            ghosttyShape = nil
            lastNonPointerCursor = .iBeam
            lastNonPointerShape = nil
            isCmuxLinkHoverActive = false
            isGhosttyLinkHoverActive = false
            pendingUnsupportedBaseAfterPointer = false
            return shouldInvalidate

        case .runtimeEnded(let runtimeLifetimeId):
            if let runtimeLifetimeId,
               activeRuntimeLifetimeId != runtimeLifetimeId {
                return false
            }
            let shouldInvalidate = (
                ghosttyShape != nil ||
                isCmuxLinkHoverActive ||
                isGhosttyLinkHoverActive
            )
            activeRuntimeLifetimeId = nil
            ghosttyCursor = .iBeam
            ghosttyShape = nil
            lastNonPointerCursor = .iBeam
            lastNonPointerShape = nil
            isCmuxLinkHoverActive = false
            isGhosttyLinkHoverActive = false
            pendingUnsupportedBaseAfterPointer = false
            return shouldInvalidate

        case .ghosttyShape(let shape, let runtimeLifetimeId):
            guard activeRuntimeLifetimeId == runtimeLifetimeId else { return false }
            guard ghosttyShape != shape else { return false }
            guard let cursor = cursor(for: shape) else {
                // Ghostty sends the terminal's base shape when an OSC 8
                // hyperlink ends. Unsupported base shapes have no AppKit
                // cursor; defer restoring the last stable fallback until the
                // matching empty-link action arrives. If no link action is
                // emitted, preserve a persistent OSC 22 pointer.
                if ghosttyShape == GHOSTTY_MOUSE_SHAPE_POINTER {
                    pendingUnsupportedBaseAfterPointer = true
                }
                return false
            }
            if shape != GHOSTTY_MOUSE_SHAPE_POINTER {
                lastNonPointerCursor = cursor
                lastNonPointerShape = shape
                pendingUnsupportedBaseAfterPointer = false
            }
            ghosttyCursor = cursor
            ghosttyShape = shape
            return isFocused &&
                !isCmuxLinkHoverActive &&
                !isGhosttyLinkHoverActive

        case .ghosttyLinkHoverChanged(let active, let runtimeLifetimeId):
            guard activeRuntimeLifetimeId == runtimeLifetimeId else { return false }
            let nextActive = isFocused && active
            if !active, pendingUnsupportedBaseAfterPointer {
                ghosttyCursor = lastNonPointerCursor
                ghosttyShape = lastNonPointerShape
                pendingUnsupportedBaseAfterPointer = false
                if !isGhosttyLinkHoverActive {
                    return isFocused && !isCmuxLinkHoverActive
                }
            }
            guard isGhosttyLinkHoverActive != nextActive else { return false }
            isGhosttyLinkHoverActive = nextActive
            return isFocused && !isCmuxLinkHoverActive

        case .focusChanged(let focused):
            guard isFocused != focused else { return false }
            isFocused = focused
            if !focused {
                isGhosttyLinkHoverActive = false
            }
            return true

        case .cmuxLinkHoverChanged(let active):
            let nextActive = active
            guard isCmuxLinkHoverActive != nextActive else { return false }
            isCmuxLinkHoverActive = nextActive
            return true
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
}
