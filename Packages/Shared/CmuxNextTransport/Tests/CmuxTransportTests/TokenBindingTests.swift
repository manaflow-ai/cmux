import Foundation
import Testing

@testable import CmuxNextTransport

/// Offline proof of the never-silent token guard: the fleet token's
/// endpoint_id claim must be extractable and comparable to the local key
/// BEFORE dialing, because the relay refuses a wrong-key token with no
/// client-visible error (the 08-20 phone stuck-at-connecting bug).
@Suite("relay token key binding (offline)")
struct TokenBindingTests {
    /// A structurally real JWT (base64url header.payload.signature) whose
    /// payload carries endpoint_id, like the fleet's mint output.
    private func token(endpointIdHex: String) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"EdDSA","typ":"JWT"}"#.utf8))
        let payload = b64url(
            Data(#"{"iss":"cmux","endpoint_id":"\#(endpointIdHex)","exp":1}"#.utf8))
        return "\(header).\(payload).c2ln"
    }

    @Test("endpoint_id claim round-trips to the identity's public key")
    func boundKeyMatches() {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d1")
        let hex = identity.publicKeyData.map { String(format: "%02x", $0) }.joined()
        #expect(IrohSubstrate.tokenEndpointId(token(endpointIdHex: hex)) == identity.publicKeyData)
    }

    @Test("A token for another device is detected as a mismatch, not a parse failure")
    func wrongKeyDetected() {
        let mine = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d1")
        let other = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d2")
        let hex = other.publicKeyData.map { String(format: "%02x", $0) }.joined()
        let bound = IrohSubstrate.tokenEndpointId(token(endpointIdHex: hex))
        #expect(bound != nil)
        #expect(bound != mine.publicKeyData)
        #expect(bound == other.publicKeyData)
    }

    @Test("Garbage tokens return nil instead of a false verdict")
    func garbageIsNil() {
        #expect(IrohSubstrate.tokenEndpointId("not-a-jwt") == nil)
        #expect(IrohSubstrate.tokenEndpointId("a.b") == nil)
        #expect(IrohSubstrate.tokenEndpointId("a.!!!.c") == nil)
        #expect(IrohSubstrate.tokenExpiry("not-a-jwt") == nil)
    }

    @Test("Expiry claim is readable so a dead credential can be named")
    func expiryReadable() {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d1")
        let hex = identity.publicKeyData.map { String(format: "%02x", $0) }.joined()
        #expect(IrohSubstrate.tokenExpiry(token(endpointIdHex: hex)) == 1)
    }

    /// The renewal push (contract 9.7 in miniature): after admission, the
    /// host delivers a fresh relay credential over the SAME ctl lane, so a
    /// live client outlives the 300s token without reconnecting. Push to an
    /// absent session reports false instead of vanishing.
    @Test("Fresh relay credential rides the established ctl lane")
    func credentialPushReachesLiveSession() async throws {
        let signer = GrantSigner()
        let now: Int64 = 1_000_000
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d1")
        let grant = try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: "g-push", issuedAt: now)
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving

        let pushed = await host.pushRelayCredential(
            deviceID: "d1", appIdentity: "dev.cmux.lite",
            url: "https://usc1.relay.cmux.dev/", token: "tok-fresh")
        #expect(pushed)

        let control = await client.lane("ctl")
        let frame = await control.receive()
        #expect(frame?.type == FrameTypes.relayCredential)
        #expect(frame?.payload["url"]?.stringValue == "https://usc1.relay.cmux.dev/")
        #expect(frame?.payload["token"]?.stringValue == "tok-fresh")

        let absent = await host.pushRelayCredential(
            deviceID: "nobody", appIdentity: "dev.cmux.lite",
            url: "https://usc1.relay.cmux.dev/", token: "tok-fresh")
        #expect(!absent)
    }

    /// Mid-session pushes race flaps and suspensions (field: none ever
    /// landed). Admission is the one moment the ctl lane is provably alive,
    /// so a queued credential is delivered right behind the admit frame.
    @Test("A queued credential is delivered at the next admission")
    func queuedCredentialDeliversOnAdmission() async throws {
        let signer = GrantSigner()
        let now: Int64 = 1_000_000
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d1")
        let grant = try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: "g-q", issuedAt: now)

        // Queued while the phone is offline: send now fails, storage sticks.
        let sent = await host.pushRelayCredential(
            deviceID: "d1", appIdentity: "dev.cmux.lite",
            url: "https://usc1.relay.cmux.dev/", token: "tok-queued")
        #expect(!sent)

        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving

        let control = await client.lane("ctl")
        let frame = await control.receive()
        #expect(frame?.type == FrameTypes.relayCredential)
        #expect(frame?.payload["token"]?.stringValue == "tok-queued")
    }

    /// The 08-22 root cause of "no push ever arrived": the ReconnectOwner is
    /// the ctl lane's single consumer, and its watch loop DISCARDED every
    /// frame; any second reader raced it and starved. Pushes must surface
    /// through the owner itself — this test runs the full owner-in-the-loop
    /// path an app actually uses.
    @Test("Pushes reach the app THROUGH the ReconnectOwner")
    func pushSurfacesThroughReconnectOwner() async throws {
        let signer = GrantSigner()
        let now: Int64 = 1_000_000
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d1")
        let grant = try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: "g-o", issuedAt: now)

        let (tokens, tokenCont) = AsyncStream<String>.makeStream()
        let owner = ReconnectOwner(
            connectOnce: {
                let (client, hostEnd) = LoopbackWire().makeEnds(
                    authenticatedClientKey: identity.publicKeyData)
                Task { await host.serve(connection: hostEnd, now: now) }
                switch try await TransportClient.connect(
                    connection: client, identity: identity, grant: grant)
                {
                case .admitted(let sessionID):
                    return .admitted(client, sessionID: sessionID)
                case .denied(let code):
                    return .denied(code)
                }
            },
            onControlFrame: { frame in
                if frame.type == FrameTypes.relayCredential,
                    let token = frame.payload["token"]?.stringValue
                {
                    tokenCont.yield(token)
                }
            })
        await owner.endpointReady(true)
        await owner.trigger(.explicit(trigger: "test"))
        for await state in await owner.states() where state == .ready { break }

        let pushed = await host.pushRelayCredential(
            deviceID: "d1", appIdentity: "dev.cmux.lite",
            url: "https://usc1.relay.cmux.dev/", token: "tok-live-push")
        #expect(pushed)

        let received = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await token in tokens { return token }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(received == "tok-live-push")
        await owner.stop(reason: .userRequested)
    }
}
