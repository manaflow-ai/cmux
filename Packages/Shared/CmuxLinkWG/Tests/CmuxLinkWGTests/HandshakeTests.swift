import CryptoKit
@testable import CmuxLinkWG
import Foundation
import Testing

@Suite("WireGuard handshake")
struct HandshakeTests {
    @Test func bothSidesDeriveTheSameKeys() throws {
        var pair = TunnelPair()
        let initiation = pair.device.beginHandshake(now: .zero).datagrams
        #expect(initiation.map(\.count) == [148])
        let response = pair.respond(initiation[0])
        #expect(response.map(\.count) == [92])
        let confirm = pair.device.decapsulate(response[0], now: .zero)
        #expect(confirm.sessionEstablished)
        #expect(confirm.datagrams.map(\.count) == [32], "an empty keepalive confirms the keys")

        // The responder cannot send until the initiator's first data packet.
        let early = pair.host.encapsulate([1, 2, 3], now: .zero)
        #expect(early.datagrams.isEmpty)
        let confirmed = pair.host.decapsulate(confirm.datagrams[0], now: .zero)
        #expect(confirmed.sessionEstablished)
        #expect(confirmed.plaintext == [])
        #expect(confirmed.datagrams.count == 1, "the staged packet leaves once confirmed")
        let staged = pair.device.decapsulate(confirmed.datagrams[0], now: .zero)
        #expect(staged.plaintext?.prefix(3) == [1, 2, 3])

        let payload = [UInt8](repeating: 7, count: 100)
        let sealed = pair.device.encapsulate(payload, now: .zero).datagrams
        #expect(sealed.count == 1)
        #expect(sealed[0].count == 16 + 112 + 16, "padded to 16 bytes plus header and tag")
        let opened = pair.host.decapsulate(sealed[0], now: .zero)
        #expect(opened.plaintext?.prefix(100).elementsEqual(payload) == true)
    }

    @Test func wrongPinnedHostKeyFailsMAC1() {
        let pair = TunnelPair()
        var device = WireGuardTunnel(
            identity: pair.deviceKey, peer: WireGuardPrivateKey().publicKey,
            timers: WireGuardTimers(), source: WireGuardHandshakeSource()
        )
        var host = pair.host
        let initiation = device.beginHandshake(now: .zero).datagrams[0]
        let output = host.decapsulate(initiation, now: .zero)
        #expect(output.error == .badMAC)
    }

    @Test func initiationFromAnotherDeviceIsRejected() {
        let pair = TunnelPair()
        var stranger = WireGuardTunnel(
            identity: WireGuardPrivateKey(), peer: pair.hostKey.publicKey,
            timers: WireGuardTimers(), source: WireGuardHandshakeSource()
        )
        var host = pair.host
        let output = host.decapsulate(stranger.beginHandshake(now: .zero).datagrams[0], now: .zero)
        #expect(output.error == .unexpectedPeer)
        #expect(output.datagrams.isEmpty)
    }

    @Test func tamperedMessagesAreRejected() {
        var pair = TunnelPair()
        var initiation = pair.device.beginHandshake(now: .zero).datagrams[0]
        initiation[50] ^= 1
        let rejected = pair.host.decapsulate(initiation, now: .zero)
        #expect(rejected.error == .badMAC)

        var fresh = TunnelPair()
        try? fresh.handshake()
        var data = fresh.device.encapsulate([1, 2, 3], now: .zero).datagrams[0]
        data[20] ^= 1
        let tampered = fresh.host.decapsulate(data, now: .zero)
        #expect(tampered.error == .decryptFailed)
    }

    @Test func replayedInitiationIsRejected() {
        var pair = TunnelPair()
        let initiation = pair.device.beginHandshake(now: .zero).datagrams[0]
        let first = pair.respond(initiation)
        #expect(first.count == 1)
        let replay = pair.host.decapsulate(initiation, now: .zero)
        #expect(replay.error == .replayedInitiation)
    }

    @Test func replayedAndReorderedDataWithinTheWindow() throws {
        var pair = TunnelPair()
        try pair.handshake()
        let packets = (0..<5).map { pair.device.encapsulate([UInt8($0)], now: .zero).datagrams[0] }
        for index in [3, 0, 4, 1, 2] {
            let output = pair.host.decapsulate(packets[index], now: .zero)
            #expect(output.plaintext?.first == UInt8(index))
        }
        let replay = pair.host.decapsulate(packets[2], now: .zero)
        #expect(replay.error == .replayedCounter)
    }

    @Test func unknownIndexIsRejected() throws {
        var pair = TunnelPair()
        try pair.handshake()
        var data = pair.device.encapsulate([1], now: .zero).datagrams[0]
        data[4] ^= 0xFF
        let output = pair.host.decapsulate(data, now: .zero)
        #expect(output.error == .unknownIndex)
    }

    /// Fixed keys, ephemeral, index and time: the initiation is byte-for-byte
    /// stable. `cmux-tui/crates/cmux-wg/tests/swift_interop.rs` feeds these
    /// bytes to boringtun, which must answer with a response.
    @Test func goldenInitiation() throws {
        let device = try WireGuardPrivateKey(rawRepresentation: Data([UInt8](1...32)))
        let host = try WireGuardPrivateKey(rawRepresentation: Data([UInt8](33...64)))
        let ephemeral = try WireGuardPrivateKey(rawRepresentation: Data([UInt8](65...96)))
        let source = WireGuardHandshakeSource(
            makeEphemeral: { ephemeral }, makeIndex: { 0x0403_0201 },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        var tunnel = WireGuardTunnel(identity: device, peer: host.publicKey, timers: WireGuardTimers(), source: source)
        let initiation = tunnel.beginHandshake(now: .zero).datagrams[0]
        #expect(device.publicKey.rawRepresentation.map { $0 }.hex == Self.devicePublic)
        #expect(host.publicKey.rawRepresentation.map { $0 }.hex == Self.hostPublic)
        #expect(initiation.hex == Self.initiation)

        // And this package's responder accepts it.
        var responder = WireGuardTunnel(identity: host, peer: device.publicKey, timers: WireGuardTimers(), source: WireGuardHandshakeSource())
        let response = responder.decapsulate(initiation, now: .zero)
        #expect(response.datagrams.map(\.count) == [92])
    }

    static let devicePublic = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c"
    static let hostPublic = "5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b"
    static let initiation = "010000000102030464b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466158a0e4ca242d151ca97ab90159a98b67e616625e68b4065d357376b6598e644ad7d678c0295d22de4cb43d5135581ed36346bfa7cf42a122139f8939935ec574414e91f3b457e447709b4db79ef84cbbce8e408d4d15bac46c2b8fb00000000000000000000000000000000"
}
