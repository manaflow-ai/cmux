import Foundation

@MainActor final class BrowserHTTPBasicAuthPromptRequest {
    typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    typealias PromptCancellation = () -> Void
    typealias PromptCancellationRegistration = (@escaping PromptCancellation) -> Void

    let key: BrowserHTTPBasicAuthProtectionSpaceKey
    let startPrompt: (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool
    private var completions: [Completion]
    private var cancelPrompt: PromptCancellation?

    init(
        key: BrowserHTTPBasicAuthProtectionSpaceKey,
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
