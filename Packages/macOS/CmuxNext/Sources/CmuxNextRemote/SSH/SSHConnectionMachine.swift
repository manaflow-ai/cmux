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
        /// The link client is up but redials its lost connection (sleep,
        /// a network drop or change); remote programs keep running there.
        case reconnecting
        case authFailed(String)
        case hostKeyUntrusted(String)
        case unreachable(String)
        case needsInstall(InstallNeed)
        case installing
        case installFailed(String)
        case failed(String)

        /// A first connection needs a visible recovery action, even while the
        /// underlying link remains eligible for automatic network retries.
        public var needsRecovery: Bool {
            switch self {
            case .unreachable, .failed, .authFailed, .hostKeyUntrusted, .installFailed: true
            default: false
            }
        }
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
        /// The running link client reports it is redialing.
        case linkInterrupted
        case linkLost
        case wake(Wake)
        case installStarted
        case installFinished(InstallOutcome)
    }

    public private(set) var status: Status = .offline
    private var blocked = true
    /// Only Reconnect (a `.user` wake) may unblock: the session is in use, which
    /// no network change, wake from sleep or activation changes.
    private var onlyUserUnblocks = false

    public init() {}

    /// Only Reconnect may open the gate now: the machine's session is in use by another cmux
    /// daemon. Nothing automatic (reconnect on use included) may take it over (HQ #4877 G5).
    public var waitsForUser: Bool { blocked && onlyUserUnblocks }

    /// Whether the link may probe and dial now.
    public var mayAttempt: Bool {
        switch status {
        case .offline, .installing: false
        default: !blocked
        }
    }

    public mutating func handle(_ event: Event) {
        if status == .offline, event != .connect { return }
        // A wake, or an automatic attempt the closed gate turns away, keeps an in-use session's
        // user-only gate (HQ #4877 G5): `.attemptStarted` only ever reopens a gate that was open.
        switch event {
        case .wake, .attemptStarted: break
        default: onlyUserUnblocks = false
        }
        switch event {
        case .connect:
            status = .connecting
            blocked = false
        case .disconnect:
            status = .offline
            blocked = true
        case .attemptStarted:
            // An automatic transport attempt may reopen only failures whose gate is
            // still eligible. Auth, host-key, install and in-use states stay blocked
            // until their authorized wake arrives.
            guard mayAttempt else { return }
            status = .connecting
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
            case .sessionInUse(let text):
                status = .failed(text)
                blocked = true
                onlyUserUnblocks = true
            }
        case .linkUp:
            status = .connected
            blocked = false
        case .linkInterrupted:
            if status == .connected { status = .reconnecting }
        case .linkLost:
            if status == .connected || status == .reconnecting { status = .connecting }
        case .wake(let wake):
            guard blocked, !onlyUserUnblocks || wake == .user else { return }
            if Self.unblocks(status, wake) {
                blocked = false
                // A user retry starts a fresh attempt immediately. Clearing the
                // old failure state prevents recovery UI from replaying it while
                // the transport opens the new connection.
                if status.needsRecovery { status = .connecting }
            }
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
