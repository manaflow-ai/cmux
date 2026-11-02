/// A machine's link as one word, the same everywhere it draws (Leo, 2026-10-28: "you just get a
/// little green dot ... as if you were working on your own computer, but now it's remote"): the
/// sidebar's machine header (`SectionHeaderRowView`) and the agent pane's composer strip
/// (`AgentPaneMachineLink`) both read it from ``SidebarMachine/Status``, so the two never disagree.
public nonisolated enum MachineLinkState: String, Hashable, Sendable {
    /// Its daemon finished the handshake (`DaemonHandshake`): a green dot. Never a bare socket or
    /// ssh connect, which reads as connecting.
    case connected
    /// On its way: connecting, reconnecting or installing. A spinner, never a pulsing dot.
    case connecting
    /// Down: offline, unreachable, sign-in refused, failed, or too old to connect. A red dot.
    case offline
    /// A Cloud machine its owner or the idle pause parked: grey; it resumes on attach.
    case paused
    /// Reachable, but cmux-tui must be installed first: the attention dot.
    case attention

    /// Whether using the machine (opening its chat, sending to it) may reconnect it on its own:
    /// a link that dropped or never came up, not one a person must fix (sign-in, an update).
    public static func reconnectsOnUse(_ status: SidebarMachine.Status) -> Bool {
        switch status {
        case .offline, .unreachable, .failed, .disconnected: true
        case .connected, .updateAvailable, .connecting, .reconnecting, .installing, .installRequired,
             .authFailed, .updateRequired, .paused, .pausedIdle, .pausing, .resuming, .deleting: false
        }
    }
}

extension SidebarMachine.Status {
    /// The status in words, as the header's tooltip and label say it ("Offline").
    @MainActor public var words: String { SectionHeaderRowView.statusWords(self) }

    /// This status as the dot draws it (``MachineLinkState``).
    public var linkState: MachineLinkState {
        switch self {
        case .connected, .updateAvailable: .connected
        case .connecting, .reconnecting, .installing, .pausing, .resuming, .deleting: .connecting
        case .offline, .unreachable, .authFailed, .failed, .updateRequired: .offline
        case .paused, .pausedIdle: .paused
        case .installRequired, .disconnected: .attention
        }
    }
}
