public import Foundation

/// The connection lifecycle of one SSH machine, as a pure reducer. It owns
/// only the decision whether an attempt may run now (``mayAttempt``) and
/// what the machine shows (``status``); the timing of attempts belongs to
/// the daemon loop (`DaemonService.start(remote:)`: capped `Backoff` after a
/// failure, then events only). Nothing here polls.
///
/// - A network failure keeps the gate open: the shared backoff paces the
///   retries and a network change, wake or activation retries at once.
/// - An authentication or host key failure closes the gate: retrying can
///   not fix a key, and hammering sshd can lock the account. The user
///   reconnecting, the app becoming active (they may have fixed their agent
///   or known_hosts elsewhere) or the Mac waking opens it again; a network
///   change does not.
/// - A missing or incompatible cmux-tui closes the gate until the user acts
///   (install, reconnect) or the app becomes active (installed by hand).
/// - Offline is the user's choice: nothing but ``Event/connect`` dials.
public struct SSHConnectionMachine: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Saved but not connected (the user disconnected, or never connected).
        case offline
        case connecting
        case connected
        case authFailed(String)
        case hostKeyUntrusted(String)
        case unreachable(String)
        case needsInstall(InstallNeed)
        case installing
        case installFailed(String)
        case failed(String)
    }

    /// Events that may let a blocked attempt succeed.
    public enum Wake: Hashable, Sendable {
        /// Reconnect, or a finished install.
        case user
        case appActivated
        case systemWake
        case networkChanged
    }

    public enum InstallOutcome: Hashable, Sendable {
        case success
        case failure(String)
    }

    public enum Event: Hashable, Sendable {
        case connect
        case disconnect
        /// The link is about to probe and dial.
        case attemptStarted
        case probed(InstallNeed)
        case failed(SSHFailure)
        case linkUp
        case linkLost
        case wake(Wake)
        case installStarted
        case installFinished(InstallOutcome)
    }

    public private(set) var status: Status = .offline
    private var blocked = true

    public init() {}

    /// Whether the link may probe and dial now.
    public var mayAttempt: Bool {
        switch status {
        case .offline, .installing: false
        default: !blocked
        }
    }

    public mutating func handle(_ event: Event) {
        if status == .offline, event != .connect { return }
        switch event {
        case .connect:
            status = .connecting
            blocked = false
        case .disconnect:
            status = .offline
            blocked = true
        case .attemptStarted:
            if status == .connected { status = .connecting }
        case .probed(let need):
            guard need != .none else { return }
            status = .needsInstall(need)
            blocked = true
        case .failed(let failure):
            switch failure {
            case .authFailed(let text):
                status = .authFailed(text)
                blocked = true
            case .hostKeyUntrusted(let text):
                status = .hostKeyUntrusted(text)
                blocked = true
            case .unreachable(let text):
                status = .unreachable(text)
                blocked = false
            case .remoteFailed(let text):
                status = .failed(text)
                blocked = false
            }
        case .linkUp:
            status = .connected
            blocked = false
        case .linkLost:
            if status == .connected { status = .connecting }
        case .wake(let wake):
            guard blocked else { return }
            if Self.unblocks(status, wake) { blocked = false }
        case .installStarted:
            status = .installing
            blocked = true
        case .installFinished(let outcome):
            switch outcome {
            case .success:
                status = .connecting
                blocked = false
            case .failure(let text):
                status = .installFailed(text)
                blocked = true
            }
        }
    }

    private static func unblocks(_ status: Status, _ wake: Wake) -> Bool {
        switch status {
        case .authFailed, .hostKeyUntrusted: wake != .networkChanged
        case .needsInstall: wake == .user || wake == .appActivated
        case .installFailed: wake == .user
        default: true
        }
    }
}
