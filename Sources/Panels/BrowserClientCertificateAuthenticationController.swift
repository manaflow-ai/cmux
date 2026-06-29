import CmuxBrowser
import Foundation
import WebKit

@MainActor final class BrowserClientCertificateAuthenticationController {
    private let promptCoordinator = BrowserClientCertificatePromptCoordinator()
    private let authenticationHandler: BrowserClientCertificateAuthenticationHandler

    init(
        candidateProvider: @escaping BrowserClientCertificateAuthenticationHandler.CandidateProvider =
            BrowserClientCertificateAuthenticationHandler.keychainCandidateProvider(protectionSpace:completion:)
    ) {
        authenticationHandler = BrowserClientCertificateAuthenticationHandler(
            candidateProvider: candidateProvider
        )
    }

    func cancelAll(allowFuturePrompts: Bool = false) {
        promptCoordinator.cancelAll(allowFuturePrompts: allowFuturePrompts)
    }

    @discardableResult
    func handle(
        challenge: URLAuthenticationChallenge,
        in webView: WKWebView,
        presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert,
        completionHandler: @escaping BrowserClientCertificateAuthenticationHandler.Completion
    ) -> Bool {
        promptCoordinator.handle(
            challenge: challenge,
            startPrompt: { [authenticationHandler, presentAlert] finishPrompt, registerCancelPrompt in
                authenticationHandler.handle(
                    challenge: challenge,
                    candidatePicker: { [presentAlert] protectionSpace, candidates, completion, registerCancelPrompt in
                        BrowserClientCertificateCredentialPicker(
                            webView: webView,
                            presentAlert: presentAlert
                        ).selectCredential(
                            for: protectionSpace,
                            candidates: candidates,
                            registerCancelPrompt: registerCancelPrompt,
                            completion: completion
                        )
                    },
                    registerCancelPrompt: registerCancelPrompt,
                    completionHandler: finishPrompt
                )
            },
            completionHandler: completionHandler
        )
    }
}
