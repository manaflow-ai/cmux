import AuthenticationServices
import Foundation
import UIKit

/// One Sign in with Apple request (full name and email). It keeps itself
/// alive until Apple answers (the controller's delegate is weak), so the
/// app's handle is only for ``cancel()``.
@MainActor
final class AppleSignIn: NSObject, SystemUICancellable {
    private let controller: ASAuthorizationController
    private var completion: ((_ identityToken: Data?, _ unexpectedCredential: Bool, _ error: (any Error)?) -> Void)?
    /// Self until Apple answers.
    private var running: AppleSignIn?

    private init(
        controller: ASAuthorizationController,
        completion: @escaping (_ identityToken: Data?, _ unexpectedCredential: Bool, _ error: (any Error)?) -> Void
    ) {
        self.controller = controller
        self.completion = completion
    }

    static func start(
        completion: @escaping (_ identityToken: Data?, _ unexpectedCredential: Bool, _ error: (any Error)?) -> Void
    ) -> AppleSignIn {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let flow = AppleSignIn(controller: controller, completion: completion)
        controller.delegate = flow
        controller.presentationContextProvider = flow
        flow.running = flow
        controller.performRequests()
        return flow
    }

    /// Reports once, on the main thread.
    private func finish(identityToken: Data?, unexpectedCredential: Bool, error: (any Error)?) {
        running = nil
        guard let completion else { return }
        self.completion = nil
        completion(identityToken, unexpectedCredential, error)
    }

    nonisolated func cancel() {
        onMain { [self] in
            if #available(iOS 16.0, *) {
                controller.cancel()
            }
        }
    }
}

extension AppleSignIn: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = UncheckedSendable(credential?.identityToken)
        let unexpected = credential == nil
        onMain { [self] in
            finish(identityToken: token.value, unexpectedCredential: unexpected, error: nil)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let error = UncheckedSendable(error)
        onMain { [self] in
            finish(identityToken: nil, unexpectedCredential: false, error: error.value)
        }
    }
}

extension AppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { PresentationAnchor.resolve() }
    }
}
