public import Foundation
public import GhosttyKit

/// Reduces pointer intent to a complete value before transport coalesces wakeups.
///
/// The state keeps OSC 22 intent pane-local, temporarily presents the normal
/// terminal pointer while the pane is unfocused, and gives cmux link hover a
/// deterministic override without using the process-wide ``NSCursor`` stack.
// SAFETY: Ghostty's imported shape enum is an immutable integer ABI value.
// Every other field is a Sendable value; no AppKit objects live in this reducer.
public struct TerminalPointerIntentState: @unchecked Sendable {
    /// Semantic identity for deduplicating factory cursors without image reads.
    private var ghosttyShape: ghostty_action_mouse_shape_e?
    /// The last supported non-pointer shape, used to restore the base cursor
    /// after Ghostty's temporary OSC 8 hyperlink pointer.
    private var lastNonPointerShape: ghostty_action_mouse_shape_e?
    /// The native lifetime authorized to change this pointer intent.
    public private(set) var activeRuntimeLifetimeId: UUID?
    private var isFocused = false
    private var isCmuxLinkHoverActive = false
    private var isGhosttyLinkHoverActive = false
    /// Raw Ghostty link state, retained independently of focus projection.
    private var hasGhosttyLinkHoverSignal = false
    /// A pointer callback may be the temporary cursor Ghostty emits while
    /// entering a link. Keep the prior base until the transition settles.
    private var hasPendingGhosttyLinkPointer = false
    /// A repeated pointer callback confirms that pointer is the persistent OSC
    /// 22 base rather than a temporary link cursor.
    private var persistentPointerBaseConfirmed = false
    /// An unsupported base shape observed after a temporary pointer is held
    /// until Ghostty's empty-link action confirms that the hyperlink ended.
    private var pendingUnsupportedBaseAfterPointer = false

    /// Creates pointer state with the normal terminal I-beam.
    public init() {}

    /// The supported shape to project into AppKit on the main actor.
    public var effectiveShape: ghostty_action_mouse_shape_e {
        if isCmuxLinkHoverActive { return GHOSTTY_MOUSE_SHAPE_POINTER }
        guard isFocused else { return GHOSTTY_MOUSE_SHAPE_TEXT }
        if isGhosttyLinkHoverActive {
            return GHOSTTY_MOUSE_SHAPE_POINTER
        }
        return ghosttyShape ?? GHOSTTY_MOUSE_SHAPE_TEXT
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
            let shouldInvalidate = resetPointerPresentationState()
            activeRuntimeLifetimeId = runtimeLifetimeId
            return shouldInvalidate

        case .runtimeReset(let runtimeLifetimeId):
            guard activeRuntimeLifetimeId == runtimeLifetimeId else { return false }
            return resetPointerPresentationState()

        case .runtimeEnded(let runtimeLifetimeId):
            if let runtimeLifetimeId,
               activeRuntimeLifetimeId != runtimeLifetimeId {
                return false
            }
            let shouldInvalidate = resetPointerPresentationState()
            activeRuntimeLifetimeId = nil
            return shouldInvalidate

        case .ghosttyShape(let shape, let runtimeLifetimeId):
            guard activeRuntimeLifetimeId == runtimeLifetimeId else { return false }
            if shape == GHOSTTY_MOUSE_SHAPE_POINTER,
               ghosttyShape == shape,
               !isGhosttyLinkHoverActive {
                // Ghostty repeats the terminal base shape when a link closes.
                // Treating that duplicate as confirmation prevents a later
                // empty-link event from erasing an explicit OSC 22 pointer.
                persistentPointerBaseConfirmed = true
                hasPendingGhosttyLinkPointer = false
                pendingUnsupportedBaseAfterPointer = false
                return false
            }
            if ghosttyShape == shape {
                // A base-shape refresh can be semantically identical to the
                // value already stored after a positive link callback. It
                // still settles the provisional-pointer bookkeeping.
                if isGhosttyLinkHoverActive {
                    hasPendingGhosttyLinkPointer = false
                    persistentPointerBaseConfirmed =
                        shape == GHOSTTY_MOUSE_SHAPE_POINTER
                    pendingUnsupportedBaseAfterPointer = false
                }
                return false
            }
            if shape == GHOSTTY_MOUSE_SHAPE_POINTER,
               isGhosttyLinkHoverActive,
               hasPendingGhosttyLinkPointer,
               !persistentPointerBaseConfirmed,
               let lastNonPointerShape {
                ghosttyShape = lastNonPointerShape
                return false
            }
            guard shape.isSupportedTerminalPointerShape else {
                // Ghostty sends the terminal's base shape when an OSC 8
                // hyperlink ends. Unsupported base shapes have no AppKit
                // cursor; defer restoring the last stable fallback until the
                // matching empty-link action arrives. A confirmed duplicate
                // pointer is persistent and should remain untouched.
                if hasPendingGhosttyLinkPointer,
                   !persistentPointerBaseConfirmed {
                    pendingUnsupportedBaseAfterPointer = true
                }
                return false
            }
            if shape == GHOSTTY_MOUSE_SHAPE_POINTER {
                if isGhosttyLinkHoverActive {
                    // This is the base shape reported while leaving a link.
                    persistentPointerBaseConfirmed = true
                    hasPendingGhosttyLinkPointer = false
                } else {
                    hasPendingGhosttyLinkPointer = true
                    persistentPointerBaseConfirmed = false
                }
            } else {
                hasPendingGhosttyLinkPointer = false
                persistentPointerBaseConfirmed = false
            }
            if shape != GHOSTTY_MOUSE_SHAPE_POINTER {
                lastNonPointerShape = shape
                pendingUnsupportedBaseAfterPointer = false
            }
            ghosttyShape = shape
            return isFocused &&
                !isCmuxLinkHoverActive &&
                !isGhosttyLinkHoverActive

        case .ghosttyLinkHoverChanged(let active, let runtimeLifetimeId):
            guard activeRuntimeLifetimeId == runtimeLifetimeId else { return false }
            let hadGhosttyLinkHoverSignal = hasGhosttyLinkHoverSignal
            hasGhosttyLinkHoverSignal = active
            let nextActive = isFocused && active
            if nextActive,
               hasPendingGhosttyLinkPointer,
               !persistentPointerBaseConfirmed {
                // Ghostty emits the temporary pointer before the positive
                // link action. Preserve a known prior base for link exit; if
                // no base exists, the pointer may be the explicit OSC 22
                // request and must remain authoritative.
                if lastNonPointerShape != nil {
                    ghosttyShape = lastNonPointerShape
                }
            }
            if !active, pendingUnsupportedBaseAfterPointer {
                if hadGhosttyLinkHoverSignal || lastNonPointerShape != nil {
                    ghosttyShape = lastNonPointerShape
                }
                pendingUnsupportedBaseAfterPointer = false
                hasPendingGhosttyLinkPointer = false
                persistentPointerBaseConfirmed = false
                if !isGhosttyLinkHoverActive { return isFocused && !isCmuxLinkHoverActive }
            }
            guard isGhosttyLinkHoverActive != nextActive else { return false }
            isGhosttyLinkHoverActive = nextActive
            return isFocused && !isCmuxLinkHoverActive

        case .focusChanged(let focused):
            guard isFocused != focused else { return false }
            isFocused = focused
            if !focused {
                if isGhosttyLinkHoverActive,
                   hasPendingGhosttyLinkPointer,
                   !persistentPointerBaseConfirmed {
                    ghosttyShape = lastNonPointerShape
                }
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

    /// Clears all runtime-owned pointer intent and reports whether the old
    /// presentation could have affected this surface's cursor rects.
    @discardableResult
    private mutating func resetPointerPresentationState() -> Bool {
        let shouldInvalidate = ghosttyShape != nil ||
            isCmuxLinkHoverActive ||
            isGhosttyLinkHoverActive
        ghosttyShape = nil
        lastNonPointerShape = nil
        isCmuxLinkHoverActive = false
        isGhosttyLinkHoverActive = false
        hasGhosttyLinkHoverSignal = false
        hasPendingGhosttyLinkPointer = false
        persistentPointerBaseConfirmed = false
        pendingUnsupportedBaseAfterPointer = false
        return shouldInvalidate
    }

}
