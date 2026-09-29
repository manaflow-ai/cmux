import Foundation

/// Performs bounded server revocations with the dependencies that own them.
struct CloudSystemVPNRevocationWorker: Sendable {
    private let service: any CloudVMServing
    private let timeout: CloudSystemVPNTaskTimeout

    init(service: any CloudVMServing, timeout: CloudSystemVPNTaskTimeout) {
        self.service = service
        self.timeout = timeout
    }

    func revoke(
        deviceFingerprint: String,
        credentials: CloudAPITokenSource.TokenPair?
    ) async throws {
        let request = Task.detached(priority: .utility) {
            if let credentials {
                try await service.revokeTunnel(
                    deviceFingerprint: deviceFingerprint,
                    tunnelPurpose: .browser,
                    accessToken: credentials.accessToken,
                    refreshToken: credentials.refreshToken
                )
            } else {
                try await service.revokeTunnel(
                    deviceFingerprint: deviceFingerprint,
                    tunnelPurpose: .browser
                )
            }
        }
        try await timeout.value(request)
    }
}
