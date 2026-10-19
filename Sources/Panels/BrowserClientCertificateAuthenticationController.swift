import CmuxBrowser
import CmuxSettings
import Foundation
import WebKit

@MainActor final class BrowserClientCertificateAuthenticationController {
    private let promptCoordinator = BrowserClientCertificatePromptCoordinator()
    private let authenticationHandler: BrowserClientCertificateAuthenticationHandler

    init(
        candidateProvider: @escaping BrowserClientCertificateAuthenticationHandler.CandidateProvider = {
            protectionSpace,
            completion in
            BrowserClientCertificateCredentialStore().lookupCandidates(
                protectionSpace: protectionSpace,
                completion: completion
            )
        },
        autoSelection: @escaping BrowserClientCertificateAuthenticationHandler.AutoSelection = BrowserClientCertificateAuthenticationController.defaultAutoSelection
    ) {
        authenticationHandler = BrowserClientCertificateAuthenticationHandler(
            candidateProvider: candidateProvider,
            autoSelection: autoSelection
        )
    }

    nonisolated static let defaultAutoSelection: BrowserClientCertificateAuthenticationHandler.AutoSelection = {
        protectionSpace,
        candidates in
        guard let selection = BrowserClientCertificateAutoSelectionPolicy(defaults: .standard)
            .selection(for: protectionSpace) else {
            return nil
        }

        switch selection {
        case .onlyCandidate:
            return candidates.count == 1 ? candidates[0] : nil
        case .certificateSerialNumber(let serialNumber):
            let normalizedCandidates = candidates.filter {
                guard let candidateSerialNumber = $0.serialNumber else { return false }
                return BrowserClientCertificateAutoSelectionRule.normalizedSerialNumber(candidateSerialNumber) == serialNumber
            }
            return normalizedCandidates.count == 1 ? normalizedCandidates[0] : nil
        }
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
            startPrompt: { [authenticationHandler, presentAlert] finishPrompt, registerCancelPrompt, isCancelled in
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
                    isCancelled: isCancelled,
                    completionHandler: finishPrompt
                )
            },
            completionHandler: completionHandler
        )
    }
}
