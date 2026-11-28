import AuthenticationServices
import Foundation
import UIKit

/// The window a sign-in sheet presents from, resolved as the app's
/// `AuthPresentationContextProvider` does: the foreground-active scene's key
/// window, else that scene's first window, else a new window on it.
@MainActor
enum PresentationAnchor {
    static func resolve() -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return UIWindow(frame: UIScreen.main.bounds)
        }
        return scene.keyWindow ?? scene.windows.first ?? UIWindow(windowScene: scene)
    }
}

/// Runs `body` on the main thread: now when already there, else next turn.
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        let box = UncheckedSendable(body)
        DispatchQueue.main.async { MainActor.assumeIsolated { box.value() } }
    }
}

/// Carries a value the caller knows is used safely across threads (a
/// completion handed back to the main thread).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// One `ASWebAuthenticationSession`. It keeps itself alive until the session
/// calls back, so the app's handle is only for ``cancel()``.
@MainActor
final class WebAuthentication: NSObject, SystemUICancellable {
    private var session: ASWebAuthenticationSession?
    /// Self while the session runs.
    private var running: WebAuthentication?

    /// Starts a session; nil when it would not start (the completion then
    /// never runs).
    static func start(
        url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool,
        completion: @escaping (URL?, (any Error)?) -> Void
    ) -> WebAuthentication? {
        let flow = WebAuthentication()
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme,
            completionHandler: completionBridge(flow: UncheckedSendable(flow), completion: UncheckedSendable(completion))
        )
        session.presentationContextProvider = flow
        session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
        flow.session = session
        flow.running = flow
        guard session.start() else {
            flow.session = nil
            flow.running = nil
            return nil
        }
        return flow
    }

    /// The session's completion. Not main-actor isolated: the session does
    /// not reliably call back on the main thread, so it hops there itself.
    private nonisolated static func completionBridge(
        flow: UncheckedSendable<WebAuthentication>,
        completion: UncheckedSendable<(URL?, (any Error)?) -> Void>
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, error in
            let result = UncheckedSendable((callbackURL, error))
            onMain {
                flow.value.session = nil
                flow.value.running = nil
                completion.value(result.value.0, result.value.1)
            }
        }
    }

    nonisolated func cancel() {
        onMain { [self] in
            session?.cancel()
        }
    }
}

extension WebAuthentication: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { PresentationAnchor.resolve() }
    }
}
