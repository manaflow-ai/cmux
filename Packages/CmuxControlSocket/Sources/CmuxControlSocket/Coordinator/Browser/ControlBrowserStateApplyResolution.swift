/// The outcome of the app-side `browser.state.load` apply pass.
public enum ControlBrowserStateApplyResolution: Sendable, Equatable {
    /// The browser surface did not resolve.
    case failure(ControlBrowserPanelFailure)
    /// The state applied (frame selector, navigation, cookies, storage — in
    /// the legacy order, best-effort as legacy).
    case applied(identity: ControlBrowserPanelIdentity)
}
