public import Foundation

/// Coordinates client-certificate prompts so repeated WebKit challenges do not stack dialogs.
@MainActor public final class BrowserClientCertificatePromptCoordinator {
    /// The completion shape expected by WebKit authentication-challenge delegates.
    public typealias Completion = BrowserClientCertificateAuthenticationHandler.Completion

    /// Registers a callback that dismisses any in-flight certificate picker.
    public typealias PromptCancellationRegistration =
        BrowserClientCertificateAuthenticationHandler.PromptCancellationRegistration

    private static let maxQueuedProtectionSpaces = 4
    private static let maxCompletionsPerProtectionSpace = 8

    private var activeRequest: BrowserClientCertificatePromptRequest?
    private var queuedRequests: [BrowserClientCertificatePromptRequest] = []
    private var isCancelling = false

    /// Creates an empty client-certificate prompt coordinator.
    public init() {}

    /// Handles or queues a client-certificate challenge.
    /// - Parameters:
    ///   - challenge: The WebKit authentication challenge.
    ///   - startPrompt: Closure that starts the prompt flow for a protection space.
    ///   - completionHandler: WebKit completion handler for the challenge.
    /// - Returns: `true` when the challenge is a client-certificate challenge and was claimed.
    @discardableResult
    public func handle(
        challenge: URLAuthenticationChallenge,
        startPrompt: @escaping (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool,
        completionHandler: @escaping Completion
    ) -> Bool {
        guard BrowserClientCertificateAuthenticationHandler.shouldHandle(challenge: challenge) else {
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

    /// Cancels active and queued prompts.
    /// - Parameter allowFuturePrompts: Whether future prompts are allowed after cancellation completes.
    public func cancelAll(allowFuturePrompts: Bool = false) {
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
