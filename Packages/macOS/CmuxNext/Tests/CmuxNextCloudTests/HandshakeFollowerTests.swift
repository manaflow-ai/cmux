import CmuxNextCloud
import Testing

/// When the app's automatic Cloud machine update offers a machine's handshake (``HandshakeFollower``).
@Suite
struct HandshakeFollowerTests {
    typealias Handshake = HandshakeFollower.Handshake

    private func offers(_ follower: inout HandshakeFollower, enabled: Bool = true, made: Bool = true,
                        _ handshakes: (String, String?)...) -> [String] {
        let due = follower.due(HandshakeFollower.Snapshot(enabled: enabled, handshakes: handshakes.map { Handshake(machineID: $0.0, key: $0.1) }))
        if made { due.forEach { follower.offered($0) } }
        return due.map(\.machineID)
    }

    /// A machine refused while the toggles are off is offered once they turn on, and once only.
    @Test func aRefusalWhileOffIsOfferedOnceTheTogglesAreOn() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, enabled: false, ("vm-1", "refused")) == [])
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", "refused")) == [], "the same handshake once")
    }

    /// Offered, then the toggles go off (the policy may drop what it queued) and on again: every
    /// live handshake is offered once more.
    @Test func anOfferIsMadeAgainAfterTheTogglesGoOffAndOn() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == ["vm-1", "vm-2"])
        #expect(offers(&follower, enabled: false, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == [])
        #expect(offers(&follower, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == ["vm-1", "vm-2"])
        #expect(offers(&follower, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == [])
    }

    /// An offer not made (no `cmux` client yet) leaves the handshake due.
    @Test func anOfferNotMadeStaysDue() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, made: false, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
    }

    /// A machine with no handshake, or gone from the list, forgets its last: a second refusal (the
    /// same key) after a drop is new, and so is a machine that comes back.
    @Test func aHandshakeAfterADropIsNew() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", nil)) == [])
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", "c1:42:1"), ("vm-2", "c2:7:1")) == ["vm-1", "vm-2"])
        #expect(offers(&follower, ("vm-2", "c2:7:1")) == [])
        #expect(offers(&follower, ("vm-1", "c1:42:1"), ("vm-2", "c2:7:1")) == ["vm-1"], "a machine gone and back")
    }
}
