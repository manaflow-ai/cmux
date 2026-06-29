import Foundation

struct BrowserClientCertificateCredentialCandidate {
    let title: String?
    let subtitle: String?
    let credential: URLCredential

    init(
        title: String? = nil,
        subtitle: String? = nil,
        credential: URLCredential
    ) {
        self.title = title
        self.subtitle = subtitle
        self.credential = credential
    }
}
