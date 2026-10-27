#if canImport(AuthenticationServices)
public import AuthenticationServices
#else
public import Foundation
#endif

/// Supplies the presentation anchor (key window) for interactive auth flows.
///
/// Conformers bridge to `ASWebAuthenticationSession` (web OAuth) and
/// `ASAuthorizationController` (native Apple Sign In), both of which require a
/// platform window to present from. The production conformer is
/// ``AuthPresentationContextProvider``; tests can supply their own. Construct it
/// once at the app composition root and inject it as `any AuthPresentationAnchoring`.
/// Where AuthenticationServices does not exist (Linux) there is no window to
/// present from, and ``StackAuthClient`` refuses OAuth sign-in.
#if canImport(AuthenticationServices)
public protocol AuthPresentationAnchoring: NSObjectProtocol,
    ASWebAuthenticationPresentationContextProviding,
    ASAuthorizationControllerPresentationContextProviding,
    Sendable {}
#else
public protocol AuthPresentationAnchoring: NSObjectProtocol, Sendable {}
#endif
