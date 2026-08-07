/// The bounded result of observing Cursor's native approval policy.
enum CursorNativeApprovalObservationOutcome: Equatable {
    case approvalRequested
    case autoApproved
    case unavailable
}
