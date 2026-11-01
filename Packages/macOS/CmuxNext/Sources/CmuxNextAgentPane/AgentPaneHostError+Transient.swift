import Foundation

nonisolated extension AgentPaneHostError {
    /// Whether the page's own retries can outlast this failure, so the pane shows nothing while it
    /// lasts (`details.reconnecting` in the handshake's failure; the page says it as one line only
    /// once it has failed past its deadline, webviews hostRetry.ts `hostErrorShows`). Leo,
    /// 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD". A daemon starting, restarting, handed
    /// off by an update, still loading, losing the start's lock race, or stopped while the page
    /// keeps looking for it all end without the person. A refusal nothing retries away is said at
    /// once: acpmux missing, another build's daemon (holder or owner known), a daemon on another
    /// home, and a daemon that refused to start from where it is.
    /// Credit: #27283 drew the restart causes from one Mac's daemon log after an update.
    var isTransient: Bool {
        switch self {
        case .timedOut, .daemonRestarting, .daemonStopped, .chiefStarting, .chiefStopped: true
        case .daemonFailed(_, let cause):
            switch cause {
            case .refused, .foreignHome: false
            case .replacedBundle, .peerRefused, .noWebSocket, .exited, .personRestart, .other: true
            }
        // A daemon of another acpmux home refuses whether or not its holder is known (AcpmuxHost.foreignHome).
        case .daemonRefused(let holder, _, let reason, _, let owner):
            holder == nil && owner == nil && !reason.hasPrefix(Self.foreignHomeReason)
        case .acpmuxNotFound: false
        }
    }

    /// The start of a foreign-home refusal's `reason`, so ``isTransient`` tells it from an unknown peer.
    static let foreignHomeReason = "it serves the acpmux home "
}
