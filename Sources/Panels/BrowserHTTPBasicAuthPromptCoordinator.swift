import Foundation

func browserShouldPromptForHTTPBasicAuth(
    challenge: URLAuthenticationChallenge
) -> Bool {
    challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
        && !challenge.protectionSpace.isProxy()
}

@MainActor final class BrowserHTTPBasicAuthPromptCoordinator {
    typealias Completion = BrowserHTTPBasicAuthPromptRequest.Completion
    typealias PromptCancellation = BrowserHTTPBasicAuthPromptRequest.PromptCancellation
    typealias PromptCancellationRegistration = BrowserHTTPBasicAuthPromptRequest.PromptCancellationRegistration

    private static let maxQueuedProtectionSpaces = 4
    private static let maxCompletionsPerProtectionSpace = 8

    private var activeRequest: BrowserHTTPBasicAuthPromptRequest?
    private var queuedRequests: [BrowserHTTPBasicAuthPromptRequest] = []
    private var isCancelling = false

    @discardableResult
    func handle(
        challenge: URLAuthenticationChallenge,
        startPrompt: @escaping (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool,
        completionHandler: @escaping Completion
    ) -> Bool {
        guard browserShouldPromptForHTTPBasicAuth(challenge: challenge) else {
            return false
        }

        guard !isCancelling else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return true
        }

        let key = BrowserHTTPBasicAuthProtectionSpaceKey(challenge.protectionSpace)
        if let activeRequest, activeRequest.key == key {
            append(completionHandler, to: activeRequest)
            return true
        }

        if let queuedRequest = queuedRequests.first(where: { $0.key == key }) {
            append(completionHandler, to: queuedRequest)
            return true
        }

        let request = BrowserHTTPBasicAuthPromptRequest(
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

    private func append(_ completion: @escaping Completion, to request: BrowserHTTPBasicAuthPromptRequest) {
        guard request.completionCount < Self.maxCompletionsPerProtectionSpace else {
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        request.appendCompletion(completion)
    }

    private func start(_ request: BrowserHTTPBasicAuthPromptRequest) {
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
