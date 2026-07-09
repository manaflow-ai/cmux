/// The outcome of waiting for a browser-side condition script to become true,
/// the package-side spelling of the app target's former nested
/// `TerminalController.V2BrowserWaitOutcome`.
///
/// The app's `typealias V2BrowserWaitOutcome = BrowserWaitOutcome` keeps every
/// existing `.met` / `.timedOut` / `.evaluationFailed(_)` reference resolving
/// unchanged.
public enum BrowserWaitOutcome: Sendable {
    /// The condition became true within the timeout.
    case met
    /// The condition did not become true before the timeout elapsed.
    case timedOut
    /// The condition script failed to evaluate, carrying the failure message.
    case evaluationFailed(String)
}
