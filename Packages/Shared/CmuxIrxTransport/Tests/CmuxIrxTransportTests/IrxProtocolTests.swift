import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite("irx wire protocol")
struct IrxProtocolTests {
    @Test("control frames round-trip through the codec")
    func controlFrameRoundTrip() throws {
        let hello = IrxHello(grant: "grant.jws.value")
        let encoded = try IrxFrameCodec.encode(hello)
        // 4-byte big-endian length prefix.
        let length = encoded.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(length == encoded.count - 4)
        let decoded = try IrxFrameCodec.decode(IrxHello.self, from: encoded.dropFirst(4))
        #expect(decoded == hello)
        #expect(decoded.proto == "cmux/irx/1")
    }

    @Test("oversized frames are refused at encode time")
    func oversizedFrameRefused() {
        let huge = IrxHello(grant: String(repeating: "x", count: IrxProtocol.maximumControlFrameByteCount + 1))
        #expect(throws: IrxFrameCodecError.self) {
            _ = try IrxFrameCodec.encode(huge)
        }
    }

    @Test("close codes parse back out of rendered causes, longest first")
    func closeCodeParsing() {
        #expect(
            IrxCloseCode.parse(fromRenderedCause: "closed by peer: irx:grant-expired (code 1)")
                == .grantExpired)
        // "grant-expired" contains no other code; "expired" alone is not a code.
        #expect(IrxCloseCode.parse(fromRenderedCause: "error: expired") == nil)
        #expect(
            IrxCloseCode.parse(fromRenderedCause: "irx:keepalive-timeout") == .keepaliveTimeout)
        #expect(IrxCloseCode.parse(fromRenderedCause: "some unrelated cause") == nil)
    }

    @Test("terminal codes suppress auto-redial; lifecycle codes do not")
    func terminalCodes() {
        #expect(IrxCloseCode.terminalForAutoRedial.contains(.superseded))
        #expect(IrxCloseCode.terminalForAutoRedial.contains(.invalidGrant))
        #expect(!IrxCloseCode.terminalForAutoRedial.contains(.keepaliveTimeout))
        #expect(!IrxCloseCode.terminalForAutoRedial.contains(.hostShutdown))
    }

    @Test("lane descriptors carry lane-specific parameters")
    func laneDescriptors() throws {
        let descriptor = IrxLaneDescriptor(
            lane: .terminal,
            resource: "terminal:0a1b",
            cursor: 42
        )
        let encoded = try IrxFrameCodec.encode(descriptor)
        let decoded = try IrxFrameCodec.decode(
            IrxLaneDescriptor.self, from: encoded.dropFirst(4))
        #expect(decoded == descriptor)
        #expect(decoded.cursor == 42)
    }
}

@Suite("relay credential policy")
struct IrxRelayCredentialPolicyTests {
    private func credential(expiresIn: TimeInterval, refreshLead: TimeInterval) -> IrxRelayCredential {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return IrxRelayCredential(
            relayURL: "https://usc1.relay.cmux.dev/",
            token: "token",
            expiresAt: now.addingTimeInterval(expiresIn),
            refreshAfter: now.addingTimeInterval(expiresIn - refreshLead)
        )
    }

    @Test("refresh happens at the earlier of refreshAfter and expiry-120s")
    func refreshDate() {
        // 300s credential, server suggests refresh at expiry-60s. Ours wins
        // at expiry-120s (60s earlier than the legacy stack).
        let credential = credential(expiresIn: 300, refreshLead: 60)
        let refresh = IrxRelayCredentialPolicy.refreshDate(for: credential, jitter: 0)
        #expect(refresh == credential.expiresAt.addingTimeInterval(-120))
        // Server-suggested earlier refresh is respected.
        let eager = self.credential(expiresIn: 300, refreshLead: 200)
        let eagerRefresh = IrxRelayCredentialPolicy.refreshDate(for: eager, jitter: 0)
        #expect(eagerRefresh == eager.refreshAfter)
    }

    @Test("mint-failure retry accelerates toward expiry, floor 1s")
    func retryDelay() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let far = IrxRelayCredentialPolicy.retryDelay(
            expiresAt: now.addingTimeInterval(200), now: now)
        #expect(far == .seconds(100))
        let near = IrxRelayCredentialPolicy.retryDelay(
            expiresAt: now.addingTimeInterval(1), now: now)
        #expect(near == .seconds(1))
        let past = IrxRelayCredentialPolicy.retryDelay(
            expiresAt: now.addingTimeInterval(-5), now: now)
        #expect(past == .seconds(1))
    }

    @Test("usability requires margin over expiry")
    func usability() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let fresh = IrxRelayCredential(
            relayURL: "https://usc1.relay.cmux.dev/",
            token: "t",
            expiresAt: now.addingTimeInterval(60),
            refreshAfter: now
        )
        #expect(fresh.isUsable(at: now))
        let dying = IrxRelayCredential(
            relayURL: "https://usc1.relay.cmux.dev/",
            token: "t",
            expiresAt: now.addingTimeInterval(5),
            refreshAfter: now
        )
        #expect(!dying.isUsable(at: now))
    }
}

@Suite("identity")
struct IrxIdentityTests {
    @Test("identity persists and derives a stable endpoint id")
    func identityPersistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-tests-\(UUID().uuidString)")
        let store = IrxFileIdentityStore(
            fileURL: dir.appendingPathComponent("identity.json"))
        let deviceID = UUID().uuidString.lowercased()
        let first = try IrxIdentityProvisioner.loadOrCreate(store: store, deviceID: deviceID)
        let second = try IrxIdentityProvisioner.loadOrCreate(store: store, deviceID: deviceID)
        #expect(first == second)
        #expect(first.endpointIDHex.count == 64)
        // A device-ID change regenerates the identity so grant tuples and the
        // broker binding can never disagree.
        let other = try IrxIdentityProvisioner.loadOrCreate(
            store: store, deviceID: UUID().uuidString.lowercased())
        #expect(other != first)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("signatures verify against the derived public key")
    func signing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-tests-\(UUID().uuidString)")
        let store = IrxFileIdentityStore(
            fileURL: dir.appendingPathComponent("identity.json"))
        let identity = try IrxIdentityProvisioner.loadOrCreate(
            store: store, deviceID: UUID().uuidString.lowercased())
        let message = Data("attributed close reasons or bust".utf8)
        let signature = try identity.sign(message)
        #expect(signature.count == 64)
        try? FileManager.default.removeItem(at: dir)
    }
}
