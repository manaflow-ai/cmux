import CmuxLink
import CmuxLinkSignaling
@_spi(Testing) import CmuxLinkWebRTC
import Foundation
import Testing

extension LiveWebRTCTests {
@Suite("Fingerprint binding")
struct FingerprintBindingTests {
    static let fp1 = "E0:89:4F:B6:0B:B0:AA:72:FE:2A:61:0C:7F:81:69:66:6F:CE:70:F7:2E:60:31:5C:22:75:78:03:C3:3B:2C:86"
    static let fp2 = "11:89:4F:B6:0B:B0:AA:72:FE:2A:61:0C:7F:81:69:66:6F:CE:70:F7:2E:60:31:5C:22:75:78:03:C3:3B:2C:86"

    @Test("one SHA-256 fingerprint per SDP; others are refused")
    func parsesFingerprints() {
        let session = "v=0\r\na=fingerprint:sha-256 \(Self.fp1.lowercased())\r\nm=application 9\r\na=fingerprint:sha-256 \(Self.fp1)\r\n"
        #expect(DTLSFingerprint(sdp: session)?.value == Self.fp1)
        #expect(DTLSFingerprint(sdp: "v=0\r\na=fingerprint:sha-256 \(Self.fp1)\r\na=fingerprint:sha-256 \(Self.fp2)\r\n") == nil)
        #expect(DTLSFingerprint(sdp: "v=0\r\na=fingerprint:sha-1 AA:BB\r\n") == nil)
        #expect(DTLSFingerprint(sdp: "v=0\r\n") == nil)
        #expect(DTLSFingerprint(value: "AA:BB") == nil)
    }

    @Test("the statement is the documented byte string")
    func statement() throws {
        let fingerprint = try #require(DTLSFingerprint(value: Self.fp1))
        let offer = try #require(DTLSFingerprint(value: Self.fp2))
        let binding = FingerprintBinding(role: .answer, session: "sess_Ab12", hostID: "h_mac", fingerprint: fingerprint, offerFingerprint: offer)
        #expect(String(decoding: binding.statement, as: UTF8.self) == "cmux.webrtc/1\nanswer\nsess_Ab12\nh_mac\n\(Self.fp1)\n\(Self.fp2)")
        let offerBinding = FingerprintBinding(role: .offer, session: "sess_Ab12", hostID: "h_mac", fingerprint: fingerprint)
        #expect(String(decoding: offerBinding.statement, as: UTF8.self).hasSuffix("\(Self.fp1)\n"))
    }

    @Test("signatures verify only for the signed binding")
    func signVerify() throws {
        let identity = SoftwareWebRTCIdentity()
        let fingerprint = try #require(DTLSFingerprint(value: Self.fp1))
        let binding = FingerprintBinding(role: .offer, session: "sess_Ab12", hostID: "h_mac", fingerprint: fingerprint)
        let auth = try binding.sign(with: identity)
        #expect(try binding.verify(auth) == identity.publicKey)

        var otherFingerprint = binding
        otherFingerprint.fingerprint = try #require(DTLSFingerprint(value: Self.fp2))
        #expect(throws: WebRTCAuthError.badSignature) { try otherFingerprint.verify(auth) }
        var otherSession = binding
        otherSession.session = "sess_Zz99"
        #expect(throws: WebRTCAuthError.badSignature) { try otherSession.verify(auth) }
        var asAnswer = binding
        asAnswer.role = .answer
        #expect(throws: WebRTCAuthError.badSignature) { try asAnswer.verify(auth) }
        #expect(throws: WebRTCAuthError.missingAuth) { try binding.verify(nil) }
        #expect(throws: WebRTCAuthError.invalidKey) { try binding.verify(SignalAuth(key: Data(count: 65), signature: auth.signature)) }

        let restored = try SoftwareWebRTCIdentity(privateKeyRepresentation: identity.privateKeyRepresentation)
        #expect(restored.publicKey == identity.publicKey)
        #expect(WebRTCPublicKey(base64: identity.publicKey.base64) == identity.publicKey)
    }

    @Test("both ends learn the key the other proved")
    func mutualIdentity() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        #expect(dialer.remoteKey == pair.hostIdentity.publicKey)
        #expect(host.remoteKey == pair.deviceIdentity.publicKey)
        #expect(host.peerIdentity?.install == WebRTCPair.phoneInstall)
        #expect(host.peerIdentity?.keyKind == .p256)
        #expect(host.peerIdentity?.publicKey == pair.deviceIdentity.publicKey.x963Representation)
        await dialer.close()
        await pair.stop()
    }

    @Test("an unpaired device gets no transport and a revoked bye")
    func unpairedDevice() async throws {
        let stranger = SoftwareWebRTCIdentity()
        let pair = await WebRTCPair(authorizedDevices: [stranger.publicKey])
        let byes = ByeRecorder()
        pair.hub.setInterceptor { message in
            if case let .bye(reason) = message.payload { byes.record(reason) }
            return message
        }
        await #expect(throws: WebRTCCarrierError.self) {
            _ = try await within { try await pair.carrier.connect(to: pair.peer) }
        }
        #expect(byes.reasons.contains(.revoked))
        await pair.stop()
    }

    @Test("a wrong pinned host key fails the dialer")
    func wrongHostKey() async throws {
        let pair = await WebRTCPair(pinnedHostKey: SoftwareWebRTCIdentity().publicKey)
        await #expect(throws: WebRTCCarrierError.self) {
            _ = try await within { try await pair.carrier.connect(to: pair.peer) }
        }
        await pair.stop()
    }

    @Test("no pinned host key, no connect")
    func noHostKey() async throws {
        let pair = await WebRTCPair()
        await #expect(throws: WebRTCCarrierError.noHostKey) {
            _ = try await pair.carrier.connect(to: LinkPeer(hostID: WebRTCPair.hostID))
        }
        await pair.stop()
    }

    /// A relay that answers with its own DTLS certificate and its own key
    /// (a man in the middle) cannot sign for the pinned host key.
    @Test("a relay that swaps the answer's auth is refused")
    func relaySwapsAuth() async throws {
        let pair = await WebRTCPair()
        let attacker = SoftwareWebRTCIdentity()
        pair.hub.setInterceptor { message in
            guard case let .answer(sdp, _) = message.payload, let fingerprint = DTLSFingerprint(sdp: sdp) else { return message }
            var forged = message
            let binding = FingerprintBinding(role: .answer, session: message.session, hostID: WebRTCPair.hostID, fingerprint: fingerprint)
            forged.payload = .answer(sdp: sdp, auth: try? binding.sign(with: attacker))
            return forged
        }
        await #expect(throws: WebRTCCarrierError.self) {
            _ = try await within { try await pair.carrier.connect(to: pair.peer) }
        }
        await pair.stop()
    }

    @Test("a relay that rewrites the offer's fingerprint is refused")
    func relayRewritesFingerprint() async throws {
        let pair = await WebRTCPair()
        let accepted = AcceptCounter()
        let incoming = pair.acceptor.incoming
        let watcher = Task { for await _ in incoming { accepted.record() } }
        pair.hub.setInterceptor { message in
            guard case let .offer(sdp, restart, carrier, auth) = message.payload else { return message }
            var forged = message
            let rewritten = sdp.replacingOccurrences(
                of: #"a=fingerprint:sha-256 [0-9A-F:]+"#, with: "a=fingerprint:sha-256 \(Self.fp2)", options: .regularExpression
            )
            forged.payload = .offer(sdp: rewritten, iceRestart: restart, carrier: carrier, auth: auth)
            return forged
        }
        await #expect(throws: WebRTCCarrierError.self) {
            _ = try await within { try await pair.carrier.connect(to: pair.peer) }
        }
        #expect(accepted.count == 0)
        watcher.cancel()
        await pair.stop()
    }
}
}

final class ByeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SignalByeReason] = []

    func record(_ reason: SignalByeReason) {
        lock.withLock { stored.append(reason) }
    }

    var reasons: [SignalByeReason] { lock.withLock { stored } }
}

final class AcceptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
