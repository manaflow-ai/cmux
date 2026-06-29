public import Foundation

/// Resolves a WebKit client-certificate challenge into a challenge disposition.
@MainActor public struct BrowserClientCertificateAuthenticationHandler {
    /// Asynchronously provides Keychain credential candidates for a protection space.
    public typealias CandidateProvider = @MainActor @Sendable (
        _ protectionSpace: URLProtectionSpace,
        _ completion: @escaping @MainActor @Sendable ([BrowserClientCertificateCredentialCandidate]) -> Void
    ) -> Void

    /// Registers a callback that dismisses any in-flight certificate picker.
    public typealias PromptCancellationRegistration = (@escaping () -> Void) -> Void

    /// Presents candidates and returns the selected candidate, or `nil` on cancellation.
    public typealias CandidatePicker = (
        _ protectionSpace: URLProtectionSpace,
        _ candidates: [BrowserClientCertificateCredentialCandidate],
        _ completion: @escaping (BrowserClientCertificateCredentialCandidate?) -> Void,
        _ registerCancelPrompt: @escaping PromptCancellationRegistration
    ) -> Void

    /// The completion shape expected by WebKit authentication-challenge delegates.
    public typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private let candidateProvider: CandidateProvider

    /// Creates a client-certificate challenge handler.
    /// - Parameter candidateProvider: Provider used to look up matching client-certificate candidates.
    public init(candidateProvider: @escaping CandidateProvider) {
        self.candidateProvider = candidateProvider
    }

    /// Handles a client-certificate challenge when applicable.
    /// - Parameters:
    ///   - challenge: The WebKit authentication challenge.
    ///   - candidatePicker: Picker used only when multiple candidates match.
    ///   - registerCancelPrompt: Callback registration used to dismiss an active picker.
    ///   - completionHandler: WebKit completion handler for the challenge.
    /// - Returns: `true` when the challenge is a client-certificate challenge and was claimed.
    @discardableResult
    public func handle(
        challenge: URLAuthenticationChallenge,
        candidatePicker: CandidatePicker? = nil,
        registerCancelPrompt: @escaping PromptCancellationRegistration = { _ in },
        completionHandler: @escaping Completion
    ) -> Bool {
        guard Self.shouldHandle(challenge: challenge) else {
            return false
        }

        candidateProvider(challenge.protectionSpace) { candidates in
            complete(
                candidates: candidates,
                protectionSpace: challenge.protectionSpace,
                candidatePicker: candidatePicker,
                registerCancelPrompt: registerCancelPrompt,
                completionHandler: completionHandler
            )
        }
        return true
    }

    /// Looks up candidates from the macOS Keychain without blocking the main actor.
    /// - Parameters:
    ///   - protectionSpace: The WebKit protection space from the client-certificate challenge.
    ///   - completion: Main-actor callback receiving matching candidates.
    public static func keychainCandidateProvider(
        protectionSpace: URLProtectionSpace,
        completion: @escaping @MainActor @Sendable ([BrowserClientCertificateCredentialCandidate]) -> Void
    ) {
        let acceptedIssuers = protectionSpace.distinguishedNames
        Task.detached(priority: .userInitiated) {
            let candidates = BrowserClientCertificateCredentialStore().candidates(acceptedIssuers: acceptedIssuers)
            await MainActor.run {
                completion(candidates)
            }
        }
    }

    static func shouldHandle(challenge: URLAuthenticationChallenge) -> Bool {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
    }

    private func complete(
        candidates: [BrowserClientCertificateCredentialCandidate],
        protectionSpace: URLProtectionSpace,
        candidatePicker: CandidatePicker?,
        registerCancelPrompt: @escaping PromptCancellationRegistration,
        completionHandler: @escaping Completion
    ) {
        switch candidates.count {
        case 0:
            completionHandler(.performDefaultHandling, nil)
        case 1:
            completionHandler(.useCredential, candidates[0].credential)
        default:
            guard let candidatePicker else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            candidatePicker(
                protectionSpace,
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
    }
}
