/// The outcome of the app-side `browser.state.save` capture pass.
public enum ControlBrowserStateCaptureResolution: Sendable, Equatable {
    /// The browser surface did not resolve.
    case failure(ControlBrowserPanelFailure)
    /// The storage readout script failed (legacy `js_error`).
    case jsError(String)
    /// The state captured.
    case captured(ControlBrowserStateCapture)
}
