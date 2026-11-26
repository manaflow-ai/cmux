import CmuxSettingsUI
import Foundation

/// Narrow auth surface consumed by the in-pane sign-in model.
@MainActor
protocol AccountSignInFlow: AnyObject {
    var currentIdentity: AccountIdentity? { get }
    var isPresentingSignIn: Bool { get }
    var isCompletingSignIn: Bool { get }
    var signInIsSlow: Bool { get }
    var lastSignInFailure: AccountSignInModel.Failure? { get }
    /// Token-free detail line for ``lastSignInFailure`` (error code, HTTP
    /// status, request ID) that a user can copy into a report.
    var lastSignInFailureDetail: String? { get }
    /// True while sign-in waits to retry after the sign-in service said
    /// too many requests came from this network.
    var isRetryingAfterRateLimit: Bool { get }
    /// True from Switch Account's sign-out until its private sign-in ends.
    var isSwitchingAccount: Bool { get }

    /// Callback-bound URL of the attempt currently presenting, if any.
    var activeSignInURL: URL? { get }

    /// Starts the shared hosted sign-in attempt and returns its callback-bound URL.
    func startSignInForPane() -> URL?

    /// Opens a previously issued sign-in URL in the default browser.
    func openSignInURLInDefaultBrowser(_ url: URL) -> Bool

    /// Copies a previously issued sign-in URL to the pasteboard.
    func copySignInURL(_ url: URL) -> Bool

    /// Copies a failure detail line to the pasteboard.
    func copyFailureDetail(_ detail: String) -> Bool
}

extension AccountSignInFlow {
    var isRetryingAfterRateLimit: Bool { false }
}
