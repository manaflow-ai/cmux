import CmuxControlPlane
import CmuxMobileWire
import Foundation
import Testing

/// `ControlPlaneClient` against an in-memory server (b1-control-do.md): hello, stream cursors and
/// gap repair, reconnect resume with pending intents, reads, signals, terminal close codes.
@Suite struct ControlPlaneClientTests {
    let host = "host_aaaaaaaaaaaaaaaaaaaa"
    var stream: String { "workspace:\(host)" }

    func makeClient(_ transport: FakeControlPlaneTransport) -> ControlPlaneClient {
        let config = ControlPlaneConfiguration(
            url: URL(string: "wss://api.test/v1/wire/host/\(host)")!,
            client: HelloClient(install: "in_phone01", platform: "ios", appVersion: "1.0.0"),
            reconnect: ReconnectPolicy(delays: [.zero], sleep: { _ in })
        )
        return ControlPlaneClient(configuration: config, transport: transport, tokenProvider: { "tok-1" })
    }

    func connected(_ client: ControlPlaneClient) async {
        for await state in client.states { if case .connected = state { return } }
    }

    func event(_ seq: UInt64) -> MobileFrame {
        .event(EventFrame(stream: stream, seq: seq, tx: "tx_\(seq)", op: "workspace.upsert", params: .object([:]), actor: [:], origin: .user, at: Int64(seq)))
    }

    @Test func helloNegotiatesAndSendsBearerSubprotocol() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        let hello = try await server.acceptHello(caps: ["read", "signal"])
        #expect(hello.proto == "cmux.mobile/1")
        #expect(hello.client.install == "in_phone01")
        await connected(client)
        #expect(await client.session?.caps == ["read", "signal"])
        #expect(transport.protocolsSeen.first == ["cmux.wire.v1", "bearer.tok-1"])
        await client.stop()
    }

    @Test func versionMismatchFailsWithoutReconnecting() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.next(.hello)
        try server.send(.error(ErrorFrame(code: "proto.version_unsupported", message: "no", retryable: false)))
        server.close(code: 4002)
        for await state in client.states {
            if case .failed(.versionUnsupported(let e)) = state { #expect(e.code == "proto.version_unsupported"); break }
        }
        #expect(transport.protocolsSeen.count == 1)
    }

    @Test func appliesContiguousEventsAndRepairsGapsFromASnapshot() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        let updates = await client.subscribe(stream)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        guard case .subscribe(let sub) = try await server.next(.subscribe) else { Issue.record("no subscribe"); return }
        #expect(sub.stream == stream)
        #expect(sub.afterSeq == nil)
        try server.send(.snapshot(SnapshotFrame(stream: stream, seq: 5, state: .object([:]), decided: [])))
        try server.send(event(6))
        try server.send(event(6))  // duplicate: dropped
        try server.send(event(8))  // gap: not applied, snapshot requested
        try server.send(event(9))  // waits for the repair
        guard case .snapshotRequest(let req) = try await server.next(.snapshotRequest) else { Issue.record("no repair"); return }
        #expect(req.stream == stream)
        try server.send(.snapshot(SnapshotFrame(stream: stream, seq: 9, state: .object([:]), decided: [])))
        try server.send(event(10))
        var seen: [String] = []
        for await u in updates {
            switch u {
            case .snapshot(let s): seen.append("snap\(s.seq)")
            case .event(let e): seen.append("ev\(e.seq)")
            }
            if seen.count == 4 { break }
        }
        #expect(seen == ["snap5", "ev6", "snap9", "ev10"])
        #expect(await client.cursor(of: stream) == 10)
        await client.stop()
    }

    func event(_ seq: UInt64, epoch: String) -> MobileFrame {
        .event(EventFrame(stream: stream, seq: seq, tx: "tx_\(seq)", op: "workspace.upsert", params: .object([:]), actor: [:], origin: .user, at: Int64(seq), epoch: epoch))
    }

    @Test func aNewEpochResetsTheCursorInsteadOfDroppingAsStale() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        let updates = await client.subscribe(stream)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        _ = try await server.next(.subscribe)
        try server.send(.snapshot(SnapshotFrame(stream: stream, seq: 40, state: .object([:]), decided: [], epoch: "ep_1_a")))
        try server.send(event(41, epoch: "ep_1_a"))
        // The Mac's store restarted: seq 3 is below the cursor but belongs to a new epoch.
        try server.send(event(3, epoch: "ep_2_b"))
        guard case .snapshotRequest(let req) = try await server.next(.snapshotRequest) else { Issue.record("no snapshot request"); return }
        #expect(req.stream == stream)
        try server.send(event(4, epoch: "ep_2_b"))  // waits for the snapshot
        try server.send(.snapshot(SnapshotFrame(stream: stream, seq: 3, state: .object([:]), decided: [], epoch: "ep_2_b")))
        try server.send(event(4, epoch: "ep_2_b"))
        var seen: [String] = []
        for await u in updates {
            switch u {
            case .snapshot(let s): seen.append("snap\(s.seq)@\(s.epoch ?? "-")")
            case .event(let e): seen.append("ev\(e.seq)@\(e.epoch ?? "-")")
            }
            if seen.count == 4 { break }
        }
        #expect(seen == ["snap40@ep_1_a", "ev41@ep_1_a", "snap3@ep_2_b", "ev4@ep_2_b"])
        #expect(await client.cursor(of: stream) == 4)

        // A reconnect resumes with the cursor's epoch, so the owner can tell a stale cursor.
        server.close(code: 1006)
        let next = try #require(await sockets.next())
        _ = try await next.acceptHello()
        guard case .subscribe(let resumed) = try await next.next(.subscribe) else { Issue.record("no resubscribe"); return }
        #expect(resumed.afterSeq == 4)
        #expect(resumed.epoch == "ep_2_b")
        await client.stop()
    }

    @Test func reconnectResumesFromTheCursorAndResendsPendingOpsWithTheirKeys() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        let updates = await client.subscribe(stream)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        _ = try await first.acceptHello()
        _ = try await first.next(.subscribe)
        try first.send(.snapshot(SnapshotFrame(stream: stream, seq: 3, state: .object([:]), decided: [])))
        var it = updates.makeAsyncIterator()
        _ = await it.next()

        let op = OpFrame(op: "workspace.rename", params: .object(["workspace": .string("ws_main01"), "name": .string("x")]), idempotencyKey: "01JB7Q2W8M0000WSREN001", origin: .user)
        let outcome = Task { try await client.submit(op) }
        guard case .op(let sent) = try await first.next(.op) else { Issue.record("no op"); return }
        #expect(sent.idempotencyKey == op.idempotencyKey)
        first.close(code: 1006)

        let second = try #require(await sockets.next())
        _ = try await second.acceptHello()
        guard case .subscribe(let resumed) = try await second.next(.subscribe) else { Issue.record("no resubscribe"); return }
        // An intent is in flight: the owner must answer with a snapshot carrying its decided key.
        #expect(resumed.pending == [op.idempotencyKey])
        guard case .op(let resent) = try await second.next(.op) else { Issue.record("no resend"); return }
        #expect(resent == op)
        try second.send(.result(ResultFrame(tx: "tx_4", idempotencyKey: op.idempotencyKey, value: .null, revision: "4", replayed: true)))
        guard case .applied(let r) = try await outcome.value else { Issue.record("not applied"); return }
        #expect(r.replayed)

        // With nothing pending, a later reconnect resumes with after_seq.
        try second.send(event(4))
        _ = await it.next()
        second.close(code: 1006)
        let third = try #require(await sockets.next())
        _ = try await third.acceptHello()
        guard case .subscribe(let again) = try await third.next(.subscribe) else { Issue.record("no resubscribe"); return }
        #expect(again.afterSeq == 4)
        #expect(again.pending == nil)
        await client.stop()
    }

    @Test func readsResolveByIdAndErrorsCarryTheCode() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(client)
        let ok = Task { try await client.read("task.list", params: .object(["host": .string(host)])) }
        guard case .read(let r1) = try await server.next(.read) else { Issue.record("no read"); return }
        let bad = Task { try await client.read("signal.turn_credentials") }
        guard case .read(let r2) = try await server.next(.read) else { Issue.record("no read"); return }
        // Answers out of order, and an error frame without `retryable` (older servers).
        server.sendRaw(#"{"t":"error","id":\#(r2.id),"code":"signal.turn_unavailable","message":"off"}"#)
        try server.send(.readResult(ReadResultFrame(id: r1.id, value: .object(["tasks": .array([])]), revision: "7")))
        #expect(try await ok.value.revision == "7")
        await #expect(throws: ControlPlaneError.remote(ErrorFrame(id: r2.id, code: "signal.turn_unavailable", message: "off", retryable: false))) { try await bad.value }
        await client.stop()
    }

    @Test func signalsFlowBothWaysAndFromIsNeverSent() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(client)
        try await client.sendSignal(SignalFrame(kind: .offer, session: "sess_abc123", to: host, from: "in_spoofed", body: ["sdp": .string("v=0")]))
        guard case .signal(let out) = try await server.next(.signal) else { Issue.record("no signal"); return }
        #expect(out.from == nil)
        #expect(out.kind == .offer)
        try server.send(.signal(SignalFrame(kind: .answer, session: "sess_abc123", to: "in_phone01", from: "inst_mac", body: ["sdp": .string("v=0")])))
        var signals = client.signals.makeAsyncIterator()
        let got = await signals.next()
        #expect(got?.kind == .answer)
        #expect(got?.from == "inst_mac")
        await client.stop()
    }

    @Test func nothingQueuesWhileDisconnectedAndRevocationIsTerminal() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await #expect(throws: ControlPlaneError.notConnected) {
            try await client.submit(OpFrame(op: "workspace.create", params: .object([:]), idempotencyKey: "create-00001"))
        }
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(client)
        server.close(code: 4401)
        for await state in client.states {
            if case .failed(.closed(let c)) = state { #expect(c.code == 4401); break }
        }
        #expect(transport.protocolsSeen.count == 1)
    }

    @Test func unknownOutcomeKeepsTheIntentForAResendWithTheSameKey() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(client)
        let op = OpFrame(op: "workspace.tab.close", params: .object(["tab": .string("tab_t01")]), idempotencyKey: "close-0001")
        let outcome = Task { try await client.submit(op) }
        _ = try await server.next(.op)
        server.sendRaw(#"{"t":"error","code":"owner.unreachable","message":"the Mac disconnected","retryable":true,"idempotency_key":"close-0001"}"#)
        // The Mac is back (seen on host:): resend; an offline refusal of the resend is not a decision.
        await client.resendPending()
        guard case .op(let again) = try await server.next(.op) else { Issue.record("no resend"); return }
        #expect(again == op)
        try server.send(.reject(RejectFrame(tx: "", idempotencyKey: op.idempotencyKey, code: "owner.unreachable", message: "offline", retryable: true, replayed: false)))
        await client.resendPending()
        _ = try await server.next(.op)
        try server.send(.result(ResultFrame(tx: "tx_1", idempotencyKey: op.idempotencyKey, value: .null, revision: "1", replayed: true)))
        guard case .applied(let r) = try await outcome.value else { Issue.record("not applied"); return }
        #expect(r.replayed)
        await client.stop()
    }

    @Test func anExpiredTokenReconnectsWithAFreshOne() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        _ = try await first.acceptHello()
        first.close(code: 4401, reason: "token expired")
        let second = try #require(await sockets.next())
        _ = try await second.acceptHello()
        #expect(transport.protocolsSeen.count == 2)
        #expect(ControlPlaneCloseError(code: 4401, reason: "install revoked").isTerminal)
        await client.stop()
    }

    @Test func reconnectsAfterRefusedConnects() async throws {
        let transport = FakeControlPlaneTransport()
        transport.refusals = 2
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(client)
        #expect(transport.protocolsSeen.count == 3)
        await client.stop()
    }
}
