import Foundation
import os

/// The authentication mode observed for one local control-socket route.
public nonisolated enum SocketAuthenticationMode: Equatable, Sendable {
    /// No request has established whether this route needs a password.
    case unknown
    /// One client is performing the single best-effort mode probe.
    case probing
    /// The route accepted a request without credentials.
    case credentialFree
    /// The route returned the local socket authentication challenge.
    case passwordRequired
    /// The mode probe failed; future one-way sends remain fire-and-forget.
    case probeFailed
}

/// Shares one route's observed authentication mode across socket clients.
///
/// Hook processes create short-lived clients for best-effort telemetry. Keeping
/// this state outside each client prevents an allow-all route from paying for a
/// blocking probe on every event while preserving password-mode authentication
/// after any client observes a challenge. The lock serializes the small state
/// transition; socket I/O remains in the caller.
public final class SocketAuthenticationModeCoordinator: @unchecked Sendable {
    // This synchronous compare-and-set state is read from blocking CLI hooks;
    // an actor would force a semaphore bridge around the socket write path.
    private let mode = OSAllocatedUnfairLock<SocketAuthenticationMode>(initialState: .unknown)

    /// Creates an initially unknown route coordinator.
    public init() {}

    /// Returns the latest mode observation.
    public var current: SocketAuthenticationMode {
        mode.withLock { $0 }
    }

    /// Claims the one probe permitted for an unknown route.
    /// - Returns: `true` only for the client that should perform the probe.
    public func claimProbe() -> Bool {
        mode.withLock { state in
            guard state == .unknown else { return false }
            state = .probing
            return true
        }
    }

    /// Records a successful credential-free response.
    public func recordCredentialFree() {
        mode.withLock { state in
            guard state != .passwordRequired else { return }
            state = .credentialFree
        }
    }

    /// Records the local socket authentication challenge.
    public func recordPasswordRequired() {
        mode.withLock { $0 = .passwordRequired }
    }

    /// Records a failed probe without making later one-way sends blocking.
    public func recordProbeFailure() {
        mode.withLock { state in
            guard state == .probing else { return }
            state = .probeFailed
        }
    }
}
