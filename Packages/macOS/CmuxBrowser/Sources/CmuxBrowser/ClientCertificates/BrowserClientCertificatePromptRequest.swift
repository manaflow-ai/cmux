import Foundation

@MainActor final class BrowserClientCertificatePromptRequest {
    typealias Completion = BrowserClientCertificateAuthenticationHandler.Completion
    typealias PromptCancellation = () -> Void
    typealias PromptCancellationRegistration = BrowserClientCertificateAuthenticationHandler.PromptCancellationRegistration
    typealias PromptCancellationCheck = BrowserClientCertificateAuthenticationHandler.PromptCancellationCheck

    let key: BrowserClientCertificateProtectionSpaceKey
    let startPrompt: (
        @escaping Completion,
        @escaping PromptCancellationRegistration,
        @escaping PromptCancellationCheck
    ) -> Bool
    private var completions: [Completion]
    private var cancelPrompts: [PromptCancellation] = []
    private(set) var isCancelled = false

    init(
        key: BrowserClientCertificateProtectionSpaceKey,
        startPrompt: @escaping (
            @escaping Completion,
            @escaping PromptCancellationRegistration,
            @escaping PromptCancellationCheck
        ) -> Bool,
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
        cancelPrompts.append(cancelPrompt)
    }

    func cancelPromptIfNeeded() {
        isCancelled = true
        let cancelPrompts = cancelPrompts
        self.cancelPrompts.removeAll()
        cancelPrompts.forEach { $0() }
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
