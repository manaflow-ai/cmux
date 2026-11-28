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

    /// Records a candidate the user picked for a protection space so later challenges skip the picker.
    public typealias SelectionRecorder = @MainActor (
        _ protectionSpace: URLProtectionSpace,
        _ candidate: BrowserClientCertificateCredentialCandidate
    ) -> Void

    private let candidateProvider: CandidateProvider
    private let selectionRecorder: SelectionRecorder?

    /// Creates a client-certificate challenge handler.
    /// - Parameters:
    ///   - candidateProvider: Provider used to look up matching client-certificate candidates.
    ///   - selectionRecorder: Called with the candidate the user picked, after the picker closes with Continue.
    public init(
        candidateProvider: @escaping CandidateProvider,
        selectionRecorder: SelectionRecorder? = nil
    ) {
        self.candidateProvider = candidateProvider
        self.selectionRecorder = selectionRecorder
    }

    /// Handles a client-certificate challenge when applicable.
    /// - Parameters:
    ///   - challenge: The WebKit authentication challenge.
    ///   - candidatePicker: Picker used when no single Keychain identity preference decides the candidate.
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
                previousFailureCount: challenge.previousFailureCount,
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
        previousFailureCount: Int,
        candidatePicker: CandidatePicker?,
        registerCancelPrompt: @escaping PromptCancellationRegistration,
        completionHandler: @escaping Completion
    ) {
        // After a failed attempt the server may be rejecting the preferred identity,
        // so let the user pick again; the new choice replaces the preference.
        let preferredCandidates = previousFailureCount == 0 ? candidates.filter(\.isPreferred) : []
        if preferredCandidates.count == 1, let preferredCandidate = preferredCandidates.first {
            completionHandler(.useCredential, preferredCandidate.credential)
            return
        }

        switch candidates.count {
        case 0:
            completionHandler(.performDefaultHandling, nil)
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
                    selectionRecorder?(protectionSpace, selectedCandidate)
                    completionHandler(.useCredential, selectedCandidate.credential)
                },
                { cancelPrompt in
                    registerCancelPrompt(cancelPrompt)
                }
            )
        }
    }
}
