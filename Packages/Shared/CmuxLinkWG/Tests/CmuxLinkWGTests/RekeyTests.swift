@testable import CmuxLinkWG
import Testing

/// WireGuard's rekey and expiry rules on the sans-IO tunnel, in simulated
/// time.
@Suite("WireGuard rekey")
struct RekeyTests {
    @Test func initiatorRekeysUnderTrafficWithoutLoss() throws {
        var pair = TunnelPair()
        try pair.handshake()
        let firstIndex = pair.device.currentLocalIndex

        pair.now = .seconds(121)
        let send = pair.device.encapsulate([1], now: pair.now)
        #expect(send.datagrams.count == 2, "data still goes under the old keys, plus an initiation")
        #expect(send.datagrams[1].first == WireGuardProtocol.initiationType)
        let data = pair.host.decapsulate(send.datagrams[0], now: pair.now)
        #expect(data.plaintext?.first == 1)

        // A packet sealed before the response is still in flight.
        let inFlight = pair.device.encapsulate([2], now: pair.now).datagrams
        #expect(inFlight.count == 1, "one rekey at a time")

        let response = pair.respond(send.datagrams[1])
        let done = pair.device.decapsulate(response[0], now: pair.now)
        #expect(done.sessionEstablished)
        #expect(pair.device.currentLocalIndex != firstIndex)

        // The previous keypair still opens the in-flight packet.
        let late = pair.host.decapsulate(inFlight[0], now: pair.now)
        #expect(late.plaintext?.first == 2)
        // New data confirms the new keys on the responder.
        let fresh = pair.device.encapsulate([3], now: pair.now).datagrams
        #expect(fresh.count == 1)
        let confirmed = pair.host.decapsulate(fresh[0], now: pair.now)
        #expect(confirmed.plaintext?.first == 3)
        #expect(confirmed.sessionEstablished)
        let reply = pair.host.encapsulate([4], now: pair.now).datagrams
        let back = pair.device.decapsulate(reply[0], now: pair.now)
        #expect(back.plaintext?.first == 4)
    }

    @Test func responderAnswersARekeyAtAnyTime() throws {
        var pair = TunnelPair()
        try pair.handshake()
        // A second initiation from the device (for example after its own
        // restart) yields a new keypair; the old one keeps working meanwhile.
        let initiation = pair.device.beginHandshake(now: .seconds(1)).datagrams[0]
        let response = pair.host.decapsulate(initiation, now: .seconds(1)).datagrams
        #expect(response.count == 1)
        let old = pair.host.encapsulate([9], now: .seconds(1)).datagrams
        #expect(old.count == 1, "current keys still send while the new ones wait for confirmation")
    }

    @Test func keysExpireAfterRejectTime() throws {
        var pair = TunnelPair()
        try pair.handshake()
        let sealed = pair.device.encapsulate([1], now: .seconds(10)).datagrams[0]
        let expired = pair.host.decapsulate(sealed, now: .seconds(181))
        #expect(expired.error == .sessionExpired)

        // The next send stages the packet and starts a handshake.
        let send = pair.device.encapsulate([2], now: .seconds(181))
        #expect(send.datagrams.count == 1)
        #expect(send.datagrams[0].first == WireGuardProtocol.initiationType)
        pair.now = .seconds(181)
        let response = pair.respond(send.datagrams[0])
        let done = pair.device.decapsulate(response[0], now: .seconds(181))
        #expect(done.sessionEstablished)
        #expect(done.datagrams.count == 1, "the staged packet")
        let delivered = pair.host.decapsulate(done.datagrams[0], now: .seconds(181))
        #expect(delivered.plaintext?.first == 2)
    }

    @Test func handshakeRetriesThenGivesUp() {
        var pair = TunnelPair(timers: WireGuardTimers(rekeyAttemptTime: .seconds(12), rekeyTimeout: .seconds(5)))
        _ = pair.device.beginHandshake(now: .zero)
        #expect(pair.device.nextDeadline() == .seconds(5))
        let retry = pair.device.updateTimers(now: .seconds(5))
        #expect(retry.datagrams.first?.first == WireGuardProtocol.initiationType)
        _ = pair.device.updateTimers(now: .seconds(10))
        let giveUp = pair.device.updateTimers(now: .seconds(15))
        #expect(giveUp.error == .handshakeTimeout)
        #expect(pair.device.nextDeadline() == nil, "an idle tunnel arms nothing")
    }

    @Test func passiveKeepaliveAfterReceive() throws {
        var pair = TunnelPair()
        try pair.handshake()
        #expect(pair.host.nextDeadline() == nil)
        let data = pair.device.encapsulate([1], now: .zero).datagrams[0]
        _ = pair.host.decapsulate(data, now: .zero)
        #expect(pair.host.nextDeadline() == .seconds(10))
        let keepalive = pair.host.updateTimers(now: .seconds(10))
        #expect(keepalive.datagrams.map(\.count) == [32])
        #expect(pair.host.nextDeadline() == nil)
    }

    @Test func silentPeerTriggersNewHandshake() throws {
        var pair = TunnelPair()
        try pair.handshake()
        _ = pair.device.encapsulate([1], now: .zero)
        #expect(pair.device.nextDeadline() == .seconds(15))
        let output = pair.device.updateTimers(now: .seconds(15))
        #expect(output.datagrams.first?.first == WireGuardProtocol.initiationType)
    }
}
