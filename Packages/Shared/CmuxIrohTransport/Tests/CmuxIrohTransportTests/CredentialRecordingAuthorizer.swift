import CMUXMobileCore
@testable import CmuxIrohTransport

/// Test authorizer that records each observed admission credential (including
/// credential-less allowlist requests) and returns a fixed authorization.
actor CredentialRecordingAuthorizer: CmxIrohAdmissionAuthorizing {
    private let authorization: CmxIrohAdmissionAuthorization
    private var credentials: [CmxIrohAdmissionCredential?] = []

    init(authorization: CmxIrohAdmissionAuthorization) {
        self.authorization = authorization
    }

    func authorize(
        credential: CmxIrohAdmissionCredential?,
        authenticatedPeerID _: CmxIrohPeerIdentity
    ) -> CmxIrohAdmissionAuthorization {
        credentials.append(credential)
        return authorization
    }

    func observedCredentials() -> [CmxIrohAdmissionCredential?] {
        credentials
    }
}
