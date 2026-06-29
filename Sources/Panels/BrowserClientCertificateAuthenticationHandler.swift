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

        _ = candidateProvider
        _ = candidatePicker
        completionHandler(.performDefaultHandling, nil)
        return true
    }
}
