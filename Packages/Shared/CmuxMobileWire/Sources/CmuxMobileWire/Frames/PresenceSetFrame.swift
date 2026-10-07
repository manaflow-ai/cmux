/// `presence.set` (cmux.wire/1): whether this client is active (app foreground, unlocked).
public struct PresenceSetFrame: Hashable, Sendable, Codable {
    public var state: PresenceState

    public init(state: PresenceState) {
        self.state = state
    }
}
