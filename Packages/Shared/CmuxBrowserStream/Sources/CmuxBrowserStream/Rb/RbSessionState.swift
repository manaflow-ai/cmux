/// Session state as the viewer sees it (`rb.state`).
public enum RbSessionState: String, Hashable, Sendable, CaseIterable {
    case idle, opening, live, paused, crashed, closed
}
