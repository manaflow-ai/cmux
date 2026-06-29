import Foundation
import WebKit

@MainActor struct BrowserClientCertificateAuthenticationHandler {
    typealias CandidateProvider = (URLProtectionSpace) -> [BrowserClientCertificateCredentialCandidate]
    typealias PromptCancellationRegistration = (@escaping () -> Void) -> Void
    typealias CandidatePicker = (
        _ protectionSpace: URLProtectionSpace,
        _ candidates: [BrowserClientCertificateCredentialCandidate],
        _ completion: @escaping (BrowserClientCertificateCredentialCandidate?) -> Void,
        _ registerCancelPrompt: @escaping PromptCancellationRegistration
    ) -> Void
    typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private let candidateProvider: CandidateProvider

    init(candidateProvider: @escaping CandidateProvider) {
        self.candidateProvider = candidateProvider
    }

    @discardableResult
    func handle(
        challenge: URLAuthenticationChallenge,
        candidatePicker: CandidatePicker? = nil,
        registerCancelPrompt: @escaping PromptCancellationRegistration = { _ in },
        completionHandler: @escaping Completion
    ) -> Bool {
        guard browserShouldHandleClientCertificateAuthentication(challenge: challenge) else {
            return false
        }

        let candidates = candidateProvider(challenge.protectionSpace)
        switch candidates.count {
        case 0:
            completionHandler(.performDefaultHandling, nil)
        default:
            guard let candidatePicker else {
                completionHandler(.performDefaultHandling, nil)
                return true
            }
            candidatePicker(
                challenge.protectionSpace,
                candidates,
                { selectedCandidate in
                    guard let selectedCandidate else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        return
                    }
                    completionHandler(.useCredential, selectedCandidate.credential)
                },
                { cancelPrompt in
                    registerCancelPrompt(cancelPrompt)
                }
            )
        }
        return true
    }
}

func browserShouldHandleClientCertificateAuthentication(
    challenge: URLAuthenticationChallenge
) -> Bool {
    challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
}

struct BrowserClientCertificateProtectionSpaceKey: Hashable {
    let host: String
    let port: Int
    let protocolName: String?
    let distinguishedNames: [Data]?
    let authenticationMethod: String

    init(_ protectionSpace: URLProtectionSpace) {
        host = protectionSpace.host
        port = protectionSpace.port
        protocolName = protectionSpace.`protocol`
        distinguishedNames = protectionSpace.distinguishedNames
        authenticationMethod = protectionSpace.authenticationMethod
    }
}

@MainActor final class BrowserClientCertificatePromptRequest {
    typealias Completion = BrowserClientCertificateAuthenticationHandler.Completion
    typealias PromptCancellation = () -> Void
    typealias PromptCancellationRegistration = BrowserClientCertificateAuthenticationHandler.PromptCancellationRegistration

    let key: BrowserClientCertificateProtectionSpaceKey
    let startPrompt: (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool
    private var completions: [Completion]
    private var cancelPrompt: PromptCancellation?

    init(
        key: BrowserClientCertificateProtectionSpaceKey,
        startPrompt: @escaping (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool,
        completion: @escaping Completion
    ) {
        self.key = key
        self.startPrompt = startPrompt
        self.completions = [completion]
    }

    var completionCount: Int {
        completions.count
    }

    func appendCompletion(_ completion: @escaping Completion) {
        completions.append(completion)
    }

    func setCancelPrompt(_ cancelPrompt: @escaping PromptCancellation) {
        self.cancelPrompt = cancelPrompt
    }

    func cancelPromptIfNeeded() {
        let cancelPrompt = cancelPrompt
        self.cancelPrompt = nil
        cancelPrompt?()
    }

    func complete(
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?
    ) {
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(disposition, credential) }
    }
}

@MainActor final class BrowserClientCertificatePromptCoordinator {
    typealias Completion = BrowserClientCertificatePromptRequest.Completion
    typealias PromptCancellationRegistration = BrowserClientCertificatePromptRequest.PromptCancellationRegistration

    private static let maxQueuedProtectionSpaces = 4
    private static let maxCompletionsPerProtectionSpace = 8

    private var activeRequest: BrowserClientCertificatePromptRequest?
    private var queuedRequests: [BrowserClientCertificatePromptRequest] = []
    private var isCancelling = false

    @discardableResult
    func handle(
        challenge: URLAuthenticationChallenge,
        startPrompt: @escaping (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool,
        completionHandler: @escaping Completion
    ) -> Bool {
        guard browserShouldHandleClientCertificateAuthentication(challenge: challenge) else {
            return false
        }

        guard !isCancelling else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return true
        }

        let key = BrowserClientCertificateProtectionSpaceKey(challenge.protectionSpace)
        if let activeRequest, activeRequest.key == key {
            append(completionHandler, to: activeRequest)
            return true
        }

        if let queuedRequest = queuedRequests.first(where: { $0.key == key }) {
            append(completionHandler, to: queuedRequest)
            return true
        }

        let request = BrowserClientCertificatePromptRequest(
            key: key,
            startPrompt: startPrompt,
            completion: completionHandler
        )
        if activeRequest == nil {
            start(request)
        } else if queuedRequests.count < Self.maxQueuedProtectionSpaces {
            queuedRequests.append(request)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
        return true
    }

    func cancelAll(allowFuturePrompts: Bool = false) {
        isCancelling = true
        let active = activeRequest
        activeRequest = nil
        let queued = queuedRequests
        queuedRequests.removeAll()
        active?.cancelPromptIfNeeded()
        active?.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
        queued.forEach {
            $0.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
        }
        if allowFuturePrompts {
            isCancelling = false
        }
    }

    private func append(_ completion: @escaping Completion, to request: BrowserClientCertificatePromptRequest) {
        guard request.completionCount < Self.maxCompletionsPerProtectionSpace else {
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        request.appendCompletion(completion)
    }

    private func start(_ request: BrowserClientCertificatePromptRequest) {
        guard !isCancelling else {
            request.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
            return
        }

        activeRequest = request
        let started = request.startPrompt(
            { [weak self, weak request] disposition, credential in
                guard let request else { return }
                guard let self else {
                    request.complete(disposition: disposition, credential: credential)
                    return
                }
                if self.activeRequest === request {
                    self.activeRequest = nil
                }
                request.complete(disposition: disposition, credential: credential)
                self.startNext()
            },
            { [weak request] cancelPrompt in
                request?.setCancelPrompt(cancelPrompt)
            }
        )

        if !started {
            if activeRequest === request {
                activeRequest = nil
            }
            request.complete(disposition: .performDefaultHandling, credential: nil)
            startNext()
        }
    }

    private func startNext() {
        guard activeRequest == nil else { return }
        guard !isCancelling else {
            let queued = queuedRequests
            queuedRequests.removeAll()
            queued.forEach {
                $0.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
            }
            return
        }
        guard !queuedRequests.isEmpty else { return }
        start(queuedRequests.removeFirst())
    }
}

@MainActor final class BrowserClientCertificateAuthenticationController {
    private let promptCoordinator = BrowserClientCertificatePromptCoordinator()
    private let authenticationHandler: BrowserClientCertificateAuthenticationHandler

    init(
        candidateProvider: @escaping BrowserClientCertificateAuthenticationHandler.CandidateProvider =
            BrowserClientCertificateCredentialStore().candidates(for:)
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
