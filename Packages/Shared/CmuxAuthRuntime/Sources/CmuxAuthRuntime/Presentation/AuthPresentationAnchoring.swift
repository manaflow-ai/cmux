public import Foundation
#if canImport(AuthenticationServices)
public import AuthenticationServices
#endif

/// Supplies the presentation anchor (key window) for interactive auth flows.
///
/// Conformers bridge to `ASWebAuthenticationSession` (web OAuth) and
/// `ASAuthorizationController` (native Apple Sign In), both of which require a
/// platform window to present from. The production conformer is
/// ``AuthPresentationContextProvider``; tests can supply their own. Construct it
/// once at the app composition root and inject it as `any AuthPresentationAnchoring`.
#if canImport(AuthenticationServices)
public protocol AuthPresentationAnchoring: NSObjectProtocol,
    ASWebAuthenticationPresentationContextProviding,
    ASAuthorizationControllerPresentationContextProviding,
    Sendable {}
#else
/// Linux's auth runtime has no presentation APIs. The protocol remains an
/// injectable anchor seam so coordinator tests can exercise the state machine.
public protocol AuthPresentationAnchoring: NSObjectProtocol, Sendable {}
#endif
