/// One bounded read step while observing a native approval log.
enum CursorNativeApprovalFileReadResult {
    case waiting
    case decision(CursorNativeApprovalObservationOutcome)
    case unavailable
}
