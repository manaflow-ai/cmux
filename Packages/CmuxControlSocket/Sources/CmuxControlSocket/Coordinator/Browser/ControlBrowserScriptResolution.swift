/// The outcome of running a coordinator-built script against a browser
/// surface: the panel-resolution failure, or the resolved identity plus the
/// JavaScript outcome.
public enum ControlBrowserScriptResolution: Sendable, Equatable {
    /// The browser surface did not resolve.
    case failure(ControlBrowserPanelFailure)
    /// The surface resolved and the script ran (or failed in JavaScript).
    case resolved(identity: ControlBrowserPanelIdentity, outcome: Outcome)

    /// The JavaScript-level outcome of a resolved script run.
    public enum Outcome: Sendable, Equatable {
        /// The run failed (legacy `.failure(message)` → wire `js_error`).
        case jsError(String)
        /// The script evaluated to JavaScript `undefined` (the legacy
        /// `V2BrowserUndefinedSentinel` result).
        case undefined
        /// The script produced a value, already passed through the legacy
        /// `v2NormalizeJSValue` and bridged to a typed JSON value.
        case value(JSONValue)
    }
}
