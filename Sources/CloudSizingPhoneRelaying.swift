import CmuxTerminalSizing

/// A weak reference to the Cloud mirror that relays phones for one surface.
struct CloudSizingRelayReference {
    weak var value: (any CloudSizingPhoneRelaying)?
}

/// A Cloud mirror session that forwards paired phones to its cmux-tui host.
@MainActor
protocol CloudSizingPhoneRelaying: AnyObject {
    /// Whether the daemon speaks shared sizing and the mirror is attached.
    var relaysPhones: Bool { get }
    /// The latest host state, if any.
    var relayedSizeState: TerminalSizingState? { get }
    /// Replaces the set of phones viewing this mirror (client id to participant).
    func relayPhones(_ phones: [String: TerminalSizingParticipant])
    /// Forwards a phone's counts override.
    func relayPhoneCountsOverride(clientID: String, value: Bool?)
    /// Forwards a phone's explicit input as activity.
    func relayPhoneActivity(clientID: String)
    /// The host participant id a phone should treat as itself.
    func relayHostParticipantID(clientID: String) -> String?
    /// Whether the host has not yet taken this phone's latest viewport, so a
    /// replay captured now would show the grid from before the phone joined.
    func relayAwaitsHost(clientID: String) -> Bool
}
