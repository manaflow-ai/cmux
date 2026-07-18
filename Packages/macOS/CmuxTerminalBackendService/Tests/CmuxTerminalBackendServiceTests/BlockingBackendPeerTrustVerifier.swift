import CmuxTerminalBackend
import CmuxTerminalBackendService
import Dispatch
import Foundation
import os

final class BlockingBackendPeerTrustVerifier: BackendPeerTrustVerifying, @unchecked Sendable {
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let invocationCountStorage = OSAllocatedUnfairLock(initialState: 0)

    func verify(_ identity: BackendPeerIdentity) throws -> BackendPeerTrustEvidence {
        invocationCountStorage.withLock { $0 += 1 }
        releaseSemaphore.wait()
        return BackendPeerTrustEvidence(
            signingIdentifier: SystemBackendPeerTrustVerifier.signingIdentifier,
            teamIdentifier: nil,
            executableURL: URL(fileURLWithPath: "/Applications/cmux.app/backend"),
            processIDVersion: 1
        )
    }

    func release() {
        releaseSemaphore.signal()
    }

    var invocationCount: Int {
        invocationCountStorage.withLock { $0 }
    }
}
