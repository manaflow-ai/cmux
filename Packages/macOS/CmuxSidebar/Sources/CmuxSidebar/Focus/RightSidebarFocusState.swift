/// The keyboard-focus lifecycle of the right sidebar as seen by the owning
/// controller: idle, a pending ``RightSidebarFocusRequest``, or focus settled on a
/// concrete ``RightSidebarMode`` and ``RightSidebarFocusTarget``.
public enum RightSidebarFocusState: Equatable {
    /// The right sidebar does not own keyboard focus.
    case inactive
    /// A focus request has been issued but not yet honored by a registered host.
    case requested(RightSidebarFocusRequest)
    /// Focus has landed on `target` within `mode`.
    case focused(mode: RightSidebarMode, target: RightSidebarFocusTarget)

    /// The active or requested mode, or `nil` while ``inactive``.
    public var mode: RightSidebarMode? {
        switch self {
        case .inactive:
            return nil
        case .requested(let request):
            return request.mode
        case .focused(let mode, _):
            return mode
        }
    }

    /// The pending request when in the ``requested(_:)`` state, else `nil`.
    public var request: RightSidebarFocusRequest? {
        if case .requested(let request) = self {
            return request
        }
        return nil
    }
}
