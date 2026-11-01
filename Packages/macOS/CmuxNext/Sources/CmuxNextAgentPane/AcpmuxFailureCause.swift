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
    /// A person asked to restart this home's daemon while a pane waited for it (``AcpmuxDaemonStop``).
    case personRestart
    /// The daemon refused to start and said why (its executable is in a runner's `_work` or a
    /// temporary folder, acpmux `daemon/exe_path.rs`); the text is shown as is.
    case refused(String)
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
        case .refused(let why):
            why
        case .replacedBundle, .foreignHome, .peerRefused, .personRestart, .other:
            // The first three are refusals: the pane says them as `daemonRefused`.
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
        case .refused(let why): "the daemon refused to start: \(why)"
        case .personRestart: "a person asked to restart the daemon while a pane waited for it"
        case .other: "the daemon could not be reached"
        }
    }
}
