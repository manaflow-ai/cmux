/// The outcome of one JavaScript evaluation against a browser surface (the
/// `Sendable` twin of the controller-private `V2JavaScriptResult`).
public enum ControlBrowserScriptOutcome: Sendable, Equatable {
    /// The script ran; its result, bridged.
    case success(ControlBrowserScriptValue)
    /// The script failed or timed out, with the legacy error message.
    case failure(String)
}
