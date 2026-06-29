import Foundation

@MainActor struct BrowserClientCertificateAuthenticationHandler {
    typealias CandidateProvider = (URLProtectionSpace) -> [BrowserClientCertificateCredentialCandidate]
    typealias CandidatePicker = (
        _ protectionSpace: URLProtectionSpace,
        _ candidates: [BrowserClientCertificateCredentialCandidate],
        _ completion: @escaping (BrowserClientCertificateCredentialCandidate?) -> Void
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
        completionHandler: @escaping Completion
    ) -> Bool {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return false
        }

        let candidates = candidateProvider(challenge.protectionSpace)
        switch candidates.count {
        case 0:
            completionHandler(.performDefaultHandling, nil)
        case 1:
            completionHandler(.useCredential, candidates[0].credential)
        default:
            guard let candidatePicker else {
                completionHandler(.performDefaultHandling, nil)
                return true
            }
            candidatePicker(challenge.protectionSpace, candidates) { selectedCandidate in
                guard let selectedCandidate else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                completionHandler(.useCredential, selectedCandidate.credential)
            }
        }
        return true
    }
}
