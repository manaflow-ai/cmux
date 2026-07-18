import CmuxTerminalBackend
import os

final class BackendServiceProbeTransportSequence: Sendable {
    private let remaining: OSAllocatedUnfairLock<[BackendServiceProbeTransport]>

    init(_ transports: [BackendServiceProbeTransport]) {
        remaining = OSAllocatedUnfairLock(initialState: transports)
    }

    func next() -> any BackendPeerIdentityTransport {
        remaining.withLock { transports in
            precondition(!transports.isEmpty, "readiness made an unexpected extra attempt")
            return transports.removeFirst()
        }
    }

    func remainingCount() -> Int {
        remaining.withLock { $0.count }
    }
}
