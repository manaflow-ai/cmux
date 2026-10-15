public import Foundation

/// Resolves a WebKit client-certificate challenge into a challenge disposition.
@MainActor public struct BrowserClientCertificateAuthenticationHandler {
    /// Cancels an in-flight client-certificate candidate lookup.
    public typealias CandidateLookupCancellation = @MainActor @Sendable () -> Void

    /// Asynchronously provides Keychain credential candidates for a protection space.
    ///
    /// Return a cancellation closure when the lookup starts work that can outlive
    /// the prompt request.
    public typealias CandidateProvider = @MainActor @Sendable (
        _ protectionSpace: URLProtectionSpace,
        _ completion: @escaping @MainActor @Sendable ([BrowserClientCertificateCredentialCandidate]) -> Void
    ) -> CandidateLookupCancellation?

    /// Registers a callback that dismisses any in-flight certificate picker.
    public typealias PromptCancellationRegistration = @MainActor (@escaping @MainActor () -> Void) -> Void

    /// Presents candidates and returns the selected candidate, or `nil` on cancellation.
    public typealias CandidatePicker = (
        _ protectionSpace: URLProtectionSpace,
        _ candidates: [BrowserClientCertificateCredentialCandidate],
        _ completion: @escaping (BrowserClientCertificateCredentialCandidate?) -> Void,
        _ registerCancelPrompt: @escaping PromptCancellationRegistration
    ) -> Void

    /// Returns whether the prompt request was canceled while lookup work was in flight.
    public typealias PromptCancellationCheck = @MainActor () -> Bool

    /// The completion shape expected by WebKit authentication-challenge delegates.
    public typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    /// Returns a candidate to use without presenting the certificate picker.
    public typealias AutoSelection = @MainActor @Sendable (
        _ protectionSpace: URLProtectionSpace,
        _ candidates: [BrowserClientCertificateCredentialCandidate]
    ) -> BrowserClientCertificateCredentialCandidate?

    private let candidateProvider: CandidateProvider
    private let autoSelection: AutoSelection?

    /// Creates a client-certificate challenge handler.
    /// - Parameters:
    ///   - candidateProvider: Provider used to look up matching client-certificate candidates.
    ///   - autoSelection: Optional policy that can select a candidate without showing a picker.
    public init(
        candidateProvider: @escaping CandidateProvider,
        autoSelection: AutoSelection? = nil
    ) {
        self.candidateProvider = candidateProvider
        self.autoSelection = autoSelection
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
        isCancelled: @escaping PromptCancellationCheck = { false },
        completionHandler: @escaping Completion
    ) -> Bool {
        guard challenge.isBrowserClientCertificateChallenge else {
            return false
        }

        let cancelLookup = candidateProvider(challenge.protectionSpace) { candidates in
            guard !isCancelled() else { return }
            complete(
                candidates: candidates,
                protectionSpace: challenge.protectionSpace,
                candidatePicker: candidatePicker,
                registerCancelPrompt: registerCancelPrompt,
                completionHandler: completionHandler
            )
        }
        if let cancelLookup {
            registerCancelPrompt(cancelLookup)
        }
        return true
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
        default:
            if let selectedCandidate = autoSelection?(protectionSpace, candidates) {
                completionHandler(.useCredential, selectedCandidate.credential)
                return
            }
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
