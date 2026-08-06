/// Meaning of a raw WebKit value after inspecting the browser-eval envelope.
public enum BrowserEvalEnvelopeResolution {
    /// The value did not use the browser-eval envelope and should pass through.
    case unwrapped(Any?)
    /// The evaluated script returned JavaScript `undefined`.
    case undefined
    /// The evaluated script returned the associated concrete value.
    case value(Any?)
    /// Sanitizing the evaluated value failed with a stable protocol error.
    case error(code: String, message: String)
}
