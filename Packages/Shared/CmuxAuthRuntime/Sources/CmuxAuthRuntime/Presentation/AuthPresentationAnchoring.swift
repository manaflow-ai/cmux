public import AuthenticationServices

/// Supplies the presentation anchor (key window) for interactive auth flows.
///
/// Conformers bridge to `ASWebAuthenticationSession` (web OAuth) and
/// `ASAuthorizationController` (native Apple Sign In), both of which require a
/// platform window to present from. The production conformer is
/// ``AuthPresentationContextProvider``; tests can supply their own. Construct it
/// once at the app composition root and inject it as `any AuthPresentationAnchoring`.
public protocol AuthPresentationAnchoring: NSObjectProtocol,
    ASWebAuthenticationPresentationContextProviding,
    ASAuthorizationControllerPresentationContextProviding,
    Sendable {}
