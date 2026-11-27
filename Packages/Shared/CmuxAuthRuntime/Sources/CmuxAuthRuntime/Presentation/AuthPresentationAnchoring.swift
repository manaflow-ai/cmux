public import Foundation
public import StackAuth

/// Supplies the system UI for interactive auth flows: web OAuth and native
/// Apple Sign In, both of which present from a platform window.
///
/// This module never imports AuthenticationServices, so an app that links
/// only `CmuxAuthRuntimeCore` does not load it at launch. The production
/// conformer is `AuthPresentationContextProvider` in `CmuxAuthRuntime`,
/// which wraps `ASWebAuthenticationSession` and `ASAuthorizationController`;
/// an app can instead forward to a framework it loads lazily, and tests can
/// supply their own. Construct it once at the app composition root and inject
/// it as `any AuthPresentationAnchoring`.
public protocol AuthPresentationAnchoring: NSObjectProtocol, Sendable {
    /// Presents the browser session and Apple Sign In sheet, or nil where
    /// this platform has none (OAuth sign-in then throws
    /// ``AuthClientError/unsupported``).
    var interactiveAuthenticator: (any StackInteractiveAuthenticator)? { get }
}
