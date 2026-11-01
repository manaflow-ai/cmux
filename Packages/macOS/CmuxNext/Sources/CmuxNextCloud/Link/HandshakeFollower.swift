/// Which Cloud machine handshakes the app's automatic update (`CloudMachineUpdates`) still has to offer: each new handshake
/// once. Only an offer that was made spends it: one left while the toggles are off, or while the
/// app has no `cmux` client, stays due. The toggles going off forget every offer, since the policy
/// may drop what it queued meanwhile: turned on again, every live handshake is offered once more
/// (the policy keeps one entry per machine and skips a machine already on the build). A machine
/// with no handshake (no connection, not refused) forgets its last, so its next one is new, also a
/// second refusal, whose key is the same.
public struct HandshakeFollower: Sendable {
    /// One machine's handshake: its id, and the key of its daemon connection (nil: none yet).
    public struct Handshake: Sendable, Equatable {
        public var machineID: String
        public var key: String?

        public init(machineID: String, key: String?) {
            self.machineID = machineID
            self.key = key
        }
    }

    /// The Cloud machines' handshakes and the toggles, as the follower sees them at once.
    public struct Snapshot: Sendable, Equatable {
        public var enabled: Bool
        public var handshakes: [Handshake]

        public init(enabled: Bool, handshakes: [Handshake]) {
            self.enabled = enabled
            self.handshakes = handshakes
        }
    }

    /// Each machine's last handshake offered.
    public private(set) var spent: [String: String] = [:]

    public init() {}

    /// The handshakes to offer now: none while the toggles are off (and every offer forgotten);
    /// else each that differs from its machine's last offered one. Forgets machines that are gone
    /// or have no handshake.
    public mutating func due(_ snapshot: Snapshot) -> [Handshake] {
        guard snapshot.enabled else {
            spent = [:]
            return []
        }
        let present = Set(snapshot.handshakes.compactMap { $0.key == nil ? nil : $0.machineID })
        spent = spent.filter { present.contains($0.key) }
        return snapshot.handshakes.filter { $0.key != nil && spent[$0.machineID] != $0.key }
    }

    /// `handshake` was offered: not due again until its machine's handshake changes.
    public mutating func offered(_ handshake: Handshake) {
        spent[handshake.machineID] = handshake.key
    }
}
