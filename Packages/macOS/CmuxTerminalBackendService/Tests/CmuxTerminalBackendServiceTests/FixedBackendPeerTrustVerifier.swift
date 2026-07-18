import CmuxTerminalBackend
import CmuxTerminalBackendService
import Foundation

struct FixedBackendPeerTrustVerifier: BackendPeerTrustVerifying {
    let shouldReject: Bool

    init(shouldReject: Bool = false) {
        self.shouldReject = shouldReject
    }

    func verify(_ identity: BackendPeerIdentity) throws -> BackendPeerTrustEvidence {
        if shouldReject {
            throw BackendPeerTrustError.executableUnavailable(
                processID: identity.processID,
                processIDVersion: 1
            )
        }
        return BackendPeerTrustEvidence(
            signingIdentifier: SystemBackendPeerTrustVerifier.signingIdentifier,
            teamIdentifier: nil,
            executableURL: URL(fileURLWithPath: "/Applications/cmux.app/backend"),
            processIDVersion: 1
        )
    }
}
