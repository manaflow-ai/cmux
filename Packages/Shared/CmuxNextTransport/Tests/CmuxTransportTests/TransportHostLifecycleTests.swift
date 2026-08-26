import Foundation
import Testing

@testable import CmuxNextTransport

/// Host-side lifecycle regressions: per-session service loops must die with
/// their session (supersession, kill, expiry — even on half-open connections
/// whose lanes never EOF), and a stored relay credential must never be
/// replayed after its token expired.
@Suite("Transport host session lifecycle")
struct TransportHostLifecycleTests {
    let signer = GrantSigner()
    let now: Int64 = 1_000_000

    private func makeHost() -> TransportHost {
        TransportHost(verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
    }

    private func mintedIdentity(
        deviceID: String = "phone-1"
    ) throws -> (PeerIdentity, PairingGrant) {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: deviceID)
        let grant = try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: "g-\(deviceID)", issuedAt: now)
        return (identity, grant)
    }

    /// Admit one connection whose HOST side is half-open: the host's closeAll
    /// cannot end the wire, so only task cancellation can stop its services.
    private func admitHalfOpen(
        host: TransportHost, identity: PeerIdentity, grant: PairingGrant
    ) async throws -> LoopbackConnectionEnd {
        let (client, hostRaw) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(
            connection: HalfOpenConnection(hostRaw), now: now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome != .denied(.malformedHello))
        await serving
        return client
    }

    /// Bounded receive: nil when nothing arrives inside the window. The
    /// timed-out reader is cancelled, so it can never steal a later frame.
    private func receiveOrTimeout(
        _ lane: any TransportLane, milliseconds: Int = 300
    ) async -> Frame? {
        await withTaskGroup(of: Frame?.self) { group in
            group.addTask { await lane.receive() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A structurally real JWT carrying only an exp claim, like the fleet's
    /// 300s tokens.
    private func expiringToken(exp: Int64) -> String {
        var payload = Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while payload.hasSuffix("=") { payload.removeLast() }
        return "aGRy.\(payload).c2ln"
    }

    @Test("Supersession cancels the old session's services, even half-open")
    func supersededServicesStop() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity()
        let oldClient = try await admitHalfOpen(host: host, identity: identity, grant: grant)

        // The old session's echo service is live.
        let echo = await oldClient.lane(TransportHost.echoLaneName)
        try await echo.send(TerminalTraffic.chunk(seq: 0, size: 64, seed: 7))
        #expect(await receiveOrTimeout(echo) != nil)

        // The same device reconnects: supersession. The old host end is
        // half-open, so the wire stays up — only cancellation can stop the
        // old loops.
        let (newClient, newHostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: newHostEnd, now: now)
        _ = try await TransportClient.connect(
            connection: newClient, identity: identity, grant: grant)
        await serving
        #expect(await host.sessionCount == 1)

        // The superseded session's echo loop must be dead. Cancellation is
        // cooperative, so at most a frame already in flight may still echo;
        // a ZOMBIE service echoes forever and never goes silent.
        #expect(await echoGoesSilent(echo, seed: 7))
    }

    /// True once a send gets no echo inside the window: the service loop is
    /// gone. A leaked loop answers every probe and never returns true.
    func echoGoesSilent(_ echo: any TransportLane, seed: UInt64) async -> Bool {
        for seq in Int64(1)...10 {
            guard
                (try? await echo.send(
                    TerminalTraffic.chunk(seq: seq, size: 64, seed: seed))) != nil
            else { return true }  // send failed: the lane itself is dead
            if await receiveOrTimeout(echo, milliseconds: 150) == nil { return true }
        }
        return false
    }
}

extension TransportHostLifecycleTests {
    @Test("killSession cancels the session's services, even half-open")
    func killedSessionServicesStop() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity()
        let client = try await admitHalfOpen(host: host, identity: identity, grant: grant)
        let echo = await client.lane(TransportHost.echoLaneName)
        try await echo.send(TerminalTraffic.chunk(seq: 0, size: 64, seed: 3))
        #expect(await receiveOrTimeout(echo) != nil)

        #expect(
            await host.killSession(
                deviceID: identity.deviceID, appIdentity: identity.appIdentity))
        #expect(await echoGoesSilent(echo, seed: 3))
    }

    @Test("An expired stored relay credential is never replayed on admission")
    func expiredPendingCredentialIsNotReplayed() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity()

        // Queued while offline, expired by the time the device reconnects.
        _ = await host.pushRelayCredential(
            deviceID: identity.deviceID, appIdentity: identity.appIdentity,
            url: "https://usc1.relay.cmux.dev/", token: expiringToken(exp: now - 30))

        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving

        // Nothing but the admit frame may ride the ctl lane: replaying the
        // stale token would hand the client a silently dead relay route.
        let control = await client.lane("ctl")
        #expect(await receiveOrTimeout(control) == nil)
    }

    @Test("A live push of an already-expired token is refused")
    func expiredLivePushIsRefused() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity()
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        _ = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        await serving

        let sent = await host.pushRelayCredential(
            deviceID: identity.deviceID, appIdentity: identity.appIdentity,
            url: "https://usc1.relay.cmux.dev/", token: expiringToken(exp: now - 30))
        #expect(!sent)
        let control = await client.lane("ctl")
        #expect(await receiveOrTimeout(control) == nil)

        // A fresh token still lands immediately.
        let fresh = await host.pushRelayCredential(
            deviceID: identity.deviceID, appIdentity: identity.appIdentity,
            url: "https://usc1.relay.cmux.dev/", token: expiringToken(exp: now + 300))
        #expect(fresh)
        #expect(await receiveOrTimeout(control)?.type == FrameTypes.relayCredential)
    }
}
