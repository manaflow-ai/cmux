import Foundation

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
    private let lock = NSLock()
    private var mode: SocketAuthenticationMode = .unknown

    /// Creates an initially unknown route coordinator.
    public init() {}

    /// Returns the latest mode observation.
    public var current: SocketAuthenticationMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    /// Claims the one probe permitted for an unknown route.
    /// - Returns: `true` only for the client that should perform the probe.
    public func claimProbe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .unknown else { return false }
        mode = .probing
        return true
    }

    /// Records a successful credential-free response.
    public func recordCredentialFree() {
        lock.lock()
        defer { lock.unlock() }
        guard mode != .passwordRequired else { return }
        mode = .credentialFree
    }

    /// Records the local socket authentication challenge.
    public func recordPasswordRequired() {
        lock.lock()
        mode = .passwordRequired
        lock.unlock()
    }

    /// Records a failed probe without making later one-way sends blocking.
    public func recordProbeFailure() {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .probing else { return }
        mode = .probeFailed
    }
}
