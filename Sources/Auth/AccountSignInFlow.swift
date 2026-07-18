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

    /// Starts the shared hosted sign-in attempt and returns its callback-bound URL.
    func startSignInForPane() -> URL?

    /// Opens a previously issued sign-in URL in the default browser.
    func openSignInURLInDefaultBrowser(_ url: URL) -> Bool

    /// Copies a previously issued sign-in URL to the pasteboard.
    func copySignInURL(_ url: URL) -> Bool
}
