/// A machine's link as one word, the same everywhere it draws (Leo, 2026-10-28: "you just get a
/// little green dot ... as if you were working on your own computer, but now it's remote"): the
/// sidebar's machine header (`SectionHeaderRowView`) and the agent pane's composer strip
/// (`AgentPaneMachineLink`) both read it from ``SidebarMachine/Status``, so the two never disagree.
/// The mapping is Rust's (`cmux-layout-reducer` `sidebar_bridge::link`, which also maps acpmux's own
/// link state); this type only names its words.
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

    /// A status's dot and whether using the machine may reconnect it on its own.
    public struct Shown: Hashable, Sendable {
        public let link: MachineLinkState
        public let reconnectsOnUse: Bool

        public init(link: MachineLinkState, reconnectsOnUse: Bool) {
            self.link = link
            self.reconnectsOnUse = reconnectsOnUse
        }
    }

    /// Rust's table, read once: a status it does not name is down and waits for a person.
    private static let table: [String: Shown] = SidebarBridgeRules().statusLinks() ?? [:]

    static func shown(_ status: SidebarMachine.Status) -> Shown {
        table[status.rawValue] ?? Shown(link: .offline, reconnectsOnUse: false)
    }

    /// Whether using the machine (opening its chat, sending to it) may reconnect it on its own:
    /// a link that dropped or never came up, not one a person must fix (sign-in, an update).
    public static func reconnectsOnUse(_ status: SidebarMachine.Status) -> Bool {
        shown(status).reconnectsOnUse
    }
}

extension SidebarMachine.Status {
    /// The status in words, as the header's tooltip and label say it ("Offline").
    @MainActor public var words: String { SectionHeaderRowView.statusWords(self) }

    /// This status as the dot draws it (``MachineLinkState``).
    public var linkState: MachineLinkState { MachineLinkState.shown(self).link }
}
