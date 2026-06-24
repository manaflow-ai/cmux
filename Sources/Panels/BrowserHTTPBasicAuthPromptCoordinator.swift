import Foundation

func browserShouldPromptForHTTPBasicAuth(
    challenge: URLAuthenticationChallenge
) -> Bool {
    challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
        && !challenge.protectionSpace.isProxy()
}

private struct BrowserHTTPBasicAuthProtectionSpaceKey: Hashable {
    let host: String
    let port: Int
    let protocolName: String?
    let realm: String?
    let authenticationMethod: String

    init(_ protectionSpace: URLProtectionSpace) {
        host = protectionSpace.host
        port = protectionSpace.port
        protocolName = protectionSpace.`protocol`
        realm = protectionSpace.realm
        authenticationMethod = protectionSpace.authenticationMethod
    }
}

@MainActor final class BrowserHTTPBasicAuthPromptCoordinator {
    typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private final class Request {
        let key: BrowserHTTPBasicAuthProtectionSpaceKey
        let startPrompt: (@escaping Completion) -> Bool
        private var completions: [Completion]

        init(
            key: BrowserHTTPBasicAuthProtectionSpaceKey,
            startPrompt: @escaping (@escaping Completion) -> Bool,
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

        func complete(
            disposition: URLSession.AuthChallengeDisposition,
            credential: URLCredential?
        ) {
            let callbacks = completions
            completions.removeAll()
            callbacks.forEach { $0(disposition, credential) }
        }
    }

    private static let maxQueuedProtectionSpaces = 4
    private static let maxCompletionsPerProtectionSpace = 8

    private var activeRequest: Request?
    private var queuedRequests: [Request] = []
    private var isCancelling = false

    @discardableResult
    func handle(
        challenge: URLAuthenticationChallenge,
        startPrompt: @escaping (@escaping Completion) -> Bool,
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

        let request = Request(
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
        active?.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
        queued.forEach {
            $0.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
        }
        if allowFuturePrompts {
            isCancelling = false
        }
    }

    private func append(_ completion: @escaping Completion, to request: Request) {
        guard request.completionCount < Self.maxCompletionsPerProtectionSpace else {
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        request.appendCompletion(completion)
    }

    private func start(_ request: Request) {
        guard !isCancelling else {
            request.complete(disposition: .cancelAuthenticationChallenge, credential: nil)
            return
        }

        activeRequest = request
        let started = request.startPrompt { [weak self, weak request] disposition, credential in
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
        }

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
