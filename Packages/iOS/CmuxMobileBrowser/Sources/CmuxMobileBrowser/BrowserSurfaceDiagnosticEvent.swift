/// Privacy-safe action and outcome boundaries emitted by the phone-local browser.
///
/// Events never contain an address, page title, form value, or page content.
/// The failure is delivered synchronously to the host so it can immediately
/// reduce it to a bounded category instead of persisting its description.
public enum BrowserSurfaceDiagnosticEvent {
    case navigateStarted
    case navigateSucceeded
    case navigateFailed(any Error)
    case backRequested
    case forwardRequested
    case reloadRequested
    case stopRequested
    case closed
}
