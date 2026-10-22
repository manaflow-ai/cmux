public import Foundation

/// Why the app could not reach an acpmux daemon, so the banner and the log name
/// the cause instead of only "did not start".
public nonisolated enum AcpmuxFailureCause: Equatable, Sendable {
    /// The daemon runs from an executable file an update replaced or deleted
    /// (Sparkle, a reinstall, `reload.sh`), so the app cannot verify it.
    case replacedBundle
    /// The daemon on the socket serves another acpmux home: another app's or tag's.
    case foreignHome
    /// The process on the socket did not pass the server peer check.
    case peerRefused
    /// The daemon answered but reported no WebSocket for the chat.
    case noWebSocket
    /// The daemon this app started exited before it was ready.
    case exited
    /// This home's daemon is alive but stopped answering, so the app restarted it
    /// (``AcpmuxUnresponsiveWatch``).
    case unresponsive
    /// After a handoff or a restart, the started daemon did not answer with the bundled build,
    /// twice (``AcpmuxHost/launch(_:replacing:)``). The pane says acpmux did not start.
    case unhealthyAfterRestart
    /// Any other failure; the log has the details.
    case other

    /// Whether the app heals this cause by itself (a handoff to the bundled
    /// acpmux), so the chat shows "restarting" instead of an error.
    var healable: Bool { self == .replacedBundle }

    /// The cause in the user's language for a `daemonFailed` banner, nil when none applies.
    var userText: String? {
        switch self {
        case .noWebSocket:
            String(localized: "agentPane.error.cause.noWebSocket", defaultValue: "it reported no chat address", bundle: .module)
        case .exited:
            String(localized: "agentPane.error.cause.exited", defaultValue: "it stopped before it was ready", bundle: .module)
        case .replacedBundle, .foreignHome, .peerRefused, .unresponsive, .unhealthyAfterRestart, .other:
            // The first three are refusals: the pane says them as `daemonRefused`. A failed start
            // after a handoff reads as "acpmux did not start", its log names the cause.
            nil
        }
    }

    /// The cause for the log, in English.
    var logText: String {
        switch self {
        case .replacedBundle: "the daemon runs from an executable file that an update replaced"
        case .foreignHome: "the socket's daemon serves another acpmux home"
        case .peerRefused: "the socket's process did not pass the server peer check"
        case .noWebSocket: "the daemon reported no WebSocket"
        case .exited: "the daemon exited before it was ready"
        case .unresponsive: "the daemon is alive but stopped answering; the app restarts it"
        case .unhealthyAfterRestart: "the daemon started after a handoff or restart did not answer with the bundled build, twice"
        case .other: "the daemon could not be reached"
        }
    }
}
