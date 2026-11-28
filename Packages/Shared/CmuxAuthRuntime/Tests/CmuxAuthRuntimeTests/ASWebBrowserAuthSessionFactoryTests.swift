import AuthenticationServices
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Pins the `ASWebAuthenticationSession` completion contract: the session does
/// not reliably deliver on the main thread (macOS 26's cancel path uses the
/// SafariLaunchAgent XPC queue), so the bridge handed to it must tolerate
/// off-main delivery and hop to the main actor itself. The pre-fix closure
/// inherited `@MainActor` isolation from the factory and trapped
/// (`dispatch_assert_queue`) on exactly this delivery.
@MainActor
@Suite struct ASWebBrowserAuthSessionFactoryTests {
    @Test func bridgeDeliveredOffMainCompletesOnMainActor() async {
        let factory = ASWebBrowserAuthSessionFactory(anchor: FakeAnchor())
        let url = URL(string: "cmux-dev://auth-callback?stack_refresh=r&stack_access=a")!
        let received: HostBrowserAuthSessionResult = await withCheckedContinuation { continuation in
            let bridge = factory.sessionCompletionBridge { result in
                // @MainActor closure: reaching here off-main would trap.
                continuation.resume(returning: result)
            }
            // Simulate the OS delivering the completion on a non-main queue.
            DispatchQueue.global(qos: .userInitiated).async {
                bridge(url, nil)
            }
        }
        #expect(received == .callback(url))
    }

    @Test func bridgeClassifiesOffMainCancellation() async {
        let factory = ASWebBrowserAuthSessionFactory(anchor: FakeAnchor())
        let received: HostBrowserAuthSessionResult = await withCheckedContinuation { continuation in
            let bridge = factory.sessionCompletionBridge { result in
                continuation.resume(returning: result)
            }
            DispatchQueue.global(qos: .utility).async {
                let error = NSError(
                    domain: ASWebAuthenticationSessionError.errorDomain,
                    code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
                )
                bridge(nil, error)
            }
        }
        #expect(received == .cancelled(reason: "canceled_login"))
    }

    @Test func bridgeClassifiesOffMainPresentationFailure() async {
        let factory = ASWebBrowserAuthSessionFactory(anchor: FakeAnchor())
        let received: HostBrowserAuthSessionResult = await withCheckedContinuation { continuation in
            let bridge = factory.sessionCompletionBridge { result in
                continuation.resume(returning: result)
            }
            DispatchQueue.global(qos: .utility).async {
                let error = NSError(
                    domain: ASWebAuthenticationSessionError.errorDomain,
                    code: ASWebAuthenticationSessionError.Code.presentationContextInvalid.rawValue
                )
                bridge(nil, error)
            }
        }
        #expect(received == .failed(reason: "presentation_context_invalid"))
    }
}
