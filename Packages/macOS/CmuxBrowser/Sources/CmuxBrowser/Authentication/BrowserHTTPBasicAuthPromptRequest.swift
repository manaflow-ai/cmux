public import Foundation

@MainActor public final class BrowserHTTPBasicAuthPromptRequest {
    public typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    public typealias PromptCancellation = () -> Void
    public typealias PromptCancellationRegistration = (@escaping PromptCancellation) -> Void

    public let key: BrowserHTTPBasicAuthProtectionSpaceKey
    public let startPrompt: (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool
    private var completions: [Completion]
    private var cancelPrompt: PromptCancellation?

    public init(
        key: BrowserHTTPBasicAuthProtectionSpaceKey,
        startPrompt: @escaping (@escaping Completion, @escaping PromptCancellationRegistration) -> Bool,
        completion: @escaping Completion
    ) {
        self.key = key
        self.startPrompt = startPrompt
        self.completions = [completion]
    }

    public var completionCount: Int {
        completions.count
    }

    public func appendCompletion(_ completion: @escaping Completion) {
        completions.append(completion)
    }

    public func setCancelPrompt(_ cancelPrompt: @escaping PromptCancellation) {
        self.cancelPrompt = cancelPrompt
    }

    public func cancelPromptIfNeeded() {
        let cancelPrompt = cancelPrompt
        self.cancelPrompt = nil
        cancelPrompt?()
    }

    public func complete(
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?
    ) {
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(disposition, credential) }
    }
}
