/// Where a ``BrowserPasskeyRequest`` stands, as the agent reads it.
public enum BrowserPasskeyStatus: String, Sendable, Hashable {
    /// Waiting for the person to click the request.
    case pending
    /// The tab was in front of the person and the trigger ran.
    case triggered
    /// The request lapsed before the person answered; nothing ran.
    case expired
    /// No such request: answered already, or replaced by a newer one.
    case unknown
}
