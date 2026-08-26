import Foundation
import Testing

@testable import CmuxPeerTransport

/// Gated LIVE test against the real staging broker and relay fleet: proves
/// register → mint → relay-only dial → admission → bytes, with real
/// endpoint-bound credentials, before any app build exists.
///
/// Enable with:
///   CMUX_PTX_RELAY_TEST=1 CMUX_PTX_STACK_EMAIL=... CMUX_PTX_STACK_PASSWORD=...
///   swift test --filter PtxRelayLiveTests
/// Optional: CMUX_PTX_HOLD_SECONDS=400 holds the session across a 300s token
/// boundary with renew loops running on both endpoints (zero-gap check).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_PTX_RELAY_TEST"] == "1"))
struct PtxRelayLiveTests {
    static let brokerBase = ProcessInfo.processInfo.environment["CMUX_PTX_BROKER_BASE"]
        ?? "https://cmux-staging.vercel.app"
    static let stackBase = "https://api.stack-auth.com"
    static let stackProject = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    static let stackPck = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"

    private static func auth() throws -> PtxBrokerAuth {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["CMUX_PTX_STACK_EMAIL"], let password = env["CMUX_PTX_STACK_PASSWORD"]
        else {
            throw PtxBrokerError.shape("missing CMUX_PTX_STACK_EMAIL/PASSWORD")
        }
        return .password(
            stackBase: stackBase, projectID: stackProject, publishableClientKey: stackPck,
            email: email, password: password)
    }

    /// File-persisted identity so registry rows don't churn per run. The
    /// broker requires device ids to be UUIDs; one is minted per role and
    /// persisted beside the key.
    private static func persistedIdentity(role: String) throws -> PtxIdentity {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/cmux-ptx-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("identity-\(role).key")
        let idFile = dir.appendingPathComponent("identity-\(role).device-id")
        let deviceID: String
        if let stored = try? String(contentsOf: idFile, encoding: .utf8),
            UUID(uuidString: stored.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        {
            deviceID = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            deviceID = UUID().uuidString.lowercased()
            try deviceID.write(to: idFile, atomically: true, encoding: .utf8)
        }
        if let data = try? Data(contentsOf: keyFile),
            let identity = try? PtxIdentity(
                deviceID: deviceID, appIdentity: "dev.cmux.ptx.test.\(role)", privateKeyData: data)
        {
            return identity
        }
        let identity = PtxIdentity.generate(
            deviceID: deviceID, appIdentity: "dev.cmux.ptx.test.\(role)")
        try identity.privateKeyData.write(to: keyFile)
        return identity
    }

    /// The broker also requires app instance ids to be UUIDs.
    private static func persistedInstanceID(role: String) throws -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/cmux-ptx-test")
        let file = dir.appendingPathComponent("identity-\(role).instance-id")
        if let stored = try? String(contentsOf: file, encoding: .utf8),
            UUID(uuidString: stored.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let minted = UUID().uuidString.lowercased()
        try minted.write(to: file, atomically: true, encoding: .utf8)
        return minted
    }

    @Test func relayOnlyDialAdmitsAndCarriesBytes() async throws {
        let log = PtxEventLog(subsystem: "dev.cmux.ptx.tests", category: "relay-live", fileURL: nil)
        let auth = try Self.auth()
        let hostIdentity = try Self.persistedIdentity(role: "host")
        let clientIdentity = try Self.persistedIdentity(role: "client")

        let hostBroker = PtxBrokerClient(
            baseURL: Self.brokerBase, auth: auth, identity: hostIdentity,
            appInstanceID: try Self.persistedInstanceID(role: "host"),
            tag: "ptxtest", platform: "mac")
        let clientBroker = PtxBrokerClient(
            baseURL: Self.brokerBase, auth: auth, identity: clientIdentity,
            appInstanceID: try Self.persistedInstanceID(role: "client"),
            tag: "ptxtest", platform: "ios")

        let mintStart = ContinuousClock.now
        let hostCredentials = try await hostBroker.registerAndMint()
        let clientCredentials = try await clientBroker.registerAndMint()
        print("[relay-live] minted host=\(hostCredentials.count) client=\(clientCredentials.count) "
            + "in \(log.elapsedMs(since: mintStart))ms; relay=\(hostCredentials[0].relayURL)")

        // ONE home relay per endpoint, like the certified lab rig: a 7-relay
        // custom map made bind() itself time out on this artifact.
        let relayURL = hostCredentials[0].relayURL
        let hostEndpoint = try await PtxEndpoint.bind(
            identity: hostIdentity,
            relays: [.init(url: relayURL, authToken: hostCredentials[0].token)])
        let clientPrimary = PtxCredentialService.preferring(clientCredentials, url: relayURL)[0]
        let clientEndpoint = try await PtxEndpoint.bind(
            identity: clientIdentity,
            relays: [.init(url: clientPrimary.relayURL, authToken: clientPrimary.token)])
        #expect(await PtxEndpoint.onlineWithin(endpoint: hostEndpoint, seconds: 15),
                "host endpoint never reached its relay")
        #expect(await PtxEndpoint.onlineWithin(endpoint: clientEndpoint, seconds: 15),
                "client endpoint never reached its relay")

        let signer = try PtxGrantSigner(
            privateKeyData: PtxIdentity.generate(deviceID: "s", appIdentity: "s").privateKeyData)
        let (admittedStream, admittedContinuation) = AsyncStream.makeStream(of: PtxHostSession.self)
        let host = PtxHost(
            identity: hostIdentity, signer: signer, log: log,
            onAdmitted: { admittedContinuation.yield($0) })
        await host.serve(endpoint: IrohEndpointBox(endpoint: hostEndpoint))

        let grant = try await host.mintGrant(
            account: "ptx-test", deviceID: clientIdentity.deviceID,
            devicePublicKey: clientIdentity.publicKeyData,
            appIdentity: clientIdentity.appIdentity)
        let ticket = PtxTicket(
            hostEndpointKey: hostIdentity.publicKeyData,
            hostSignerKey: signer.publicKeyData,
            hostDeviceID: hostIdentity.deviceID,
            relayURL: relayURL,
            directAddresses: [])

        let dialStart = ContinuousClock.now
        let outcome = try await PtxClient.connect(
            endpoint: clientEndpoint,
            plan: PtxClient.DialPlan(ticket: ticket, relayOnly: true),
            identity: clientIdentity, grant: grant, log: log)
        let dialMs = log.elapsedMs(since: dialStart)
        guard case .admitted(let session) = outcome else {
            Issue.record("relay-only dial not admitted: \(outcome)")
            return
        }
        print("[relay-live] relay-only dial -> admitted in \(dialMs)ms")
        #expect(dialMs < 5000, "relay dial took \(dialMs)ms")

        var iterator = admittedStream.makeAsyncIterator()
        let hostSession = await iterator.next()
        #expect(hostSession != nil)

        // Bytes across the relay in both directions over one raw stream.
        let raw = try await session.connection.openRawStream(
            descriptor: "{\"lane\":\"terminal\",\"resource_id\":\"relay-test\"}")
        let payload = Data(repeating: 0x5A, count: 64 * 1024)
        try await raw.write(payload)
        let echoed = await withCheckedContinuation {
            (continuation: CheckedContinuation<Int, Never>) in
            Task {
                await hostSession!.connection.onRawStream { _, stream in
                    var buffer = stream.handshakeRemainder
                    var total = buffer.count
                    while total < payload.count {
                        guard
                            let chunk = try? await stream.read(
                                maximumByteCount: 1 << 16, consumedBuffer: &buffer)
                        else { break }
                        total += chunk.count
                    }
                    continuation.resume(returning: total)
                }
            }
        }
        #expect(echoed == payload.count)

        // Optional long hold across the 300s token boundary with live
        // renewal (zero-gap rotation) on both endpoints.
        let hold = Int(ProcessInfo.processInfo.environment["CMUX_PTX_HOLD_SECONDS"] ?? "20") ?? 20
        if hold > 0 {
            let holdStart = ContinuousClock.now
            var renewTasks: [Task<Void, Never>] = []
            for (broker, endpoint) in [(hostBroker, hostEndpoint), (clientBroker, clientEndpoint)] {
                renewTasks.append(
                    Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(60))
                            if let minted = try? await broker.mint() {
                                let ordered = PtxCredentialService.preferring(
                                    minted, url: relayURL)
                                if let primary = ordered.first {
                                    _ = await PtxEndpoint.rotateRelay(
                                        endpoint: endpoint, url: primary.relayURL,
                                        token: primary.token, log: log)
                                }
                            }
                        }
                    })
            }
            var pingFailures = 0
            while log.elapsedMs(since: holdStart) < Int64(hold) * 1000 {
                try? await Task.sleep(for: .seconds(10))
                do {
                    try await session.control.sendFrame(
                        PtxFrame(type: PtxFrameType.ping))
                } catch {
                    pingFailures += 1
                }
                let closed = await session.connection.isClosed
                if closed {
                    let cause = await session.connection.termination() ?? "unattributed"
                    let heldMs = log.elapsedMs(since: holdStart)
                    Issue.record("session died at +\(heldMs)ms: \(cause)")
                    break
                }
                print("[relay-live] held \(log.elapsedMs(since: holdStart) / 1000)s "
                    + "closed=\(closed)")
            }
            for task in renewTasks { task.cancel() }
            #expect(pingFailures == 0)
            let finallyClosed = await session.connection.isClosed
            #expect(!finallyClosed, "session did not survive the hold")
        }

        await session.connection.close(reason: PtxCloseReason.userRequested.rawValue)
        try? await hostEndpoint.close()
        try? await clientEndpoint.close()
    }
}
