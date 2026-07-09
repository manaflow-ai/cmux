/// A value reducer owning the right sidebar's keyboard-focus lifecycle: the
/// current ``RightSidebarFocusState`` plus a monotonic request counter that makes
/// each ``RightSidebarFocusRequest`` supersede the previous one. The owning
/// `@MainActor` controller holds one inline instance and drives every focus
/// transition through it.
public struct RightSidebarFocusStateMachine {
    /// The right sidebar's keyboard-focus state.
    public var state: RightSidebarFocusState

    /// Monotonic source for request identifiers, advanced on each
    /// ``beginRequest(mode:target:)`` so a later request supersedes an earlier one.
    private var nextRequestId: UInt64

    /// Creates a state machine, defaulting to ``RightSidebarFocusState/inactive``.
    public init(state: RightSidebarFocusState = .inactive) {
        self.state = state
        self.nextRequestId = 0
    }

    /// Whether a responder claiming `responderMode` may take right-sidebar focus
    /// given the pending request, if any. A request constrains acceptance to its
    /// own mode, and a fallback sidebar host only when the request targets
    /// ``RightSidebarFocusTarget/host``.
    public func canAcceptResponderFocus(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) -> Bool {
        guard let request = state.request else {
            return true
        }
        if responderMode != request.mode {
            return false
        }
        if isFallbackSidebarHost, request.target != .host {
            return false
        }
        return true
    }

    /// Settles focus onto a responder reporting `responderMode`, honoring the
    /// pending request's target when present, else landing on
    /// ``RightSidebarFocusTarget/host``.
    public mutating func completeFocusFromResponder(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) {
        guard let request = state.request else {
            state = .focused(mode: responderMode, target: .host)
            return
        }
        guard request.mode == responderMode else { return }
        if isFallbackSidebarHost, request.target != .host {
            return
        }
        state = .focused(mode: request.mode, target: request.target)
    }

    /// Issues a new focus request for `mode`/`target`, advancing the monotonic id
    /// so it supersedes any earlier request.
    public mutating func beginRequest(mode: RightSidebarMode, target: RightSidebarFocusTarget) {
        nextRequestId &+= 1
        state = .requested(
            RightSidebarFocusRequest(
                id: nextRequestId,
                mode: mode,
                target: target
            )
        )
    }
}
