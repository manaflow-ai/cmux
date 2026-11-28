#if os(iOS)
import CmuxAuthRuntimeCore
import CmuxMobileSystemUIBridge
import Foundation
import StackAuth

/// The app's ``AuthPresentationAnchoring``: web OAuth and Sign in with Apple
/// run in CmuxMobileSystemUI.framework (``SystemUI/provider``), which the app
/// loads on first use, so the app binary does not link AuthenticationServices.
/// Without the framework OAuth sign-in throws `AuthClientError.unsupported`.
final class SystemUIAuthPresentationAnchor: NSObject, AuthPresentationAnchoring {
    var interactiveAuthenticator: (any StackInteractiveAuthenticator)? {
        SystemUI.provider.map { SystemUIInteractiveAuthenticator(provider: $0) }
    }
}

/// Forwards StackAuth's interactive flows to the framework's
/// `ASWebAuthenticationSession` and `ASAuthorizationController`. The
/// framework passes their errors through with domain and code unchanged, so
/// StackAuth maps them exactly as it maps AuthenticationServices' own.
/// `@unchecked`: the provider is only used on the main actor.
private final class SystemUIInteractiveAuthenticator: StackInteractiveAuthenticator, @unchecked Sendable {
    private let provider: any SystemUIProvider

    init(provider: any SystemUIProvider) {
        self.provider = provider
    }

    @MainActor
    func startWebAuthentication(
        url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool,
        completion: @escaping @Sendable (URL?, StackSystemAuthError?) -> Void
    ) -> (any StackInteractiveAuthSession)? {
        // `@Sendable` keeps the closure nonisolated: one formed here would
        // inherit main-actor isolation and Swift 6 would trap if the
        // framework ever called it off the main thread.
        let handle = provider.startWebAuthentication(
            url: url,
            callbackScheme: callbackScheme,
            prefersEphemeralSession: prefersEphemeralSession
        ) { @Sendable callbackURL, error in
            let systemError = error.map { StackSystemAuthError($0) }
            deliverOnMain { completion(callbackURL, systemError) }
        }
        return handle.map { SystemUIAuthSession($0) }
    }

    @MainActor
    func startAppleSignIn(
        completion: @escaping @Sendable (StackAppleSignInResult) -> Void
    ) -> any StackInteractiveAuthSession {
        let handle = provider.startAppleSignIn { @Sendable identityToken, unexpectedCredential, error in
            let result: StackAppleSignInResult
            if let error {
                result = .failure(StackSystemAuthError(error))
            } else if unexpectedCredential {
                result = .unexpectedCredential
            } else {
                result = .credential(identityToken: identityToken)
            }
            deliverOnMain { completion(result) }
        }
        return SystemUIAuthSession(handle)
    }
}

/// A running framework flow, cancelled through its handle.
private final class SystemUIAuthSession: StackInteractiveAuthSession {
    private let handle: any SystemUICancellable

    init(_ handle: any SystemUICancellable) {
        self.handle = handle
    }

    @MainActor
    func cancel() {
        handle.cancel()
    }
}

/// Runs `body` now when on the main thread, else on the main queue: the
/// authenticator contract delivers every completion on main.
private func deliverOnMain(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.async(execute: body)
    }
}
#endif
