import CmuxControlPlane
import CmuxMobileWire
import Foundation
import Testing

/// One HostDO socket per Mac shared by every feature (D1b): leases fan out
/// states, signals and stream updates; the last release closes the socket.
@Suite struct HostSocketPoolTests {
    let host = "host_aaaaaaaaaaaaaaaaaaaa"

    final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(String, String?)] = []
        var calls: [(String, String?)] { lock.withLock { _calls } }
        func add(_ host: String, _ team: String?) { lock.withLock { _calls.append((host, team)) } }
    }

    func pool(_ transport: FakeControlPlaneTransport, made: Made = Made()) -> HostSocketPool {
        HostSocketPool { host, team in
            made.add(host, team)
            let config = ControlPlaneConfiguration(
                url: URL(string: "wss://api.test/v1/wire/host/\(host)")!,
                client: HelloClient(install: "in_phone01", platform: "ios", appVersion: "1.0.0"),
                reconnect: ReconnectPolicy(delays: [.zero], sleep: { _ in }))
            return ControlPlaneClient(configuration: config, transport: transport, tokenProvider: { "tok-1" })
        }
    }

    func connected(_ session: any ControlPlaneSession) async {
        for await state in await session.stateUpdates() { if case .connected = state { return } }
    }

    func snapshot(_ stream: String, _ seq: UInt64) -> MobileFrame {
        .snapshot(SnapshotFrame(stream: stream, seq: seq, state: .object([:]), decided: []))
    }

    @Test func twoFeaturesShareOneSocketAndBothReadTheHostStream() async throws {
        let transport = FakeControlPlaneTransport()
        let pool = pool(transport)
        let workspaces = await pool.session(host: host)
        let signaling = await pool.session(host: host)
        await workspaces.start()
        await signaling.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(workspaces)
        await connected(signaling)

        let first = await workspaces.subscribe("host:\(host)")
        guard case .subscribe = try await server.next(.subscribe) else { Issue.record("no subscribe"); return }
        try server.send(snapshot("host:\(host)", 3))
        var firstIterator = first.makeAsyncIterator()
        #expect(await firstIterator.next() == .snapshot(SnapshotFrame(stream: "host:\(host)", seq: 3, state: .object([:]), decided: [])))

        // A second reader of the same stream: subscribed again, the fresh snapshot reaches both.
        let second = await signaling.subscribe("host:\(host)")
        _ = try await server.next(.subscribe)
        try server.send(snapshot("host:\(host)", 4))
        try server.send(.event(EventFrame(stream: "host:\(host)", seq: 5, tx: "tx_5", op: "host.presence.set",
                                          params: .object([:]), actor: [:], origin: .user, at: 5)))
        var secondIterator = second.makeAsyncIterator()
        for iterator in [0, 1] {
            let updates: [StreamUpdate?] = iterator == 0
                ? [await firstIterator.next(), await firstIterator.next()]
                : [await secondIterator.next(), await secondIterator.next()]
            guard case .snapshot(let s)? = updates[0], case .event(let e)? = updates[1] else {
                Issue.record("lease \(iterator) got \(updates)")
                continue
            }
            #expect(s.seq == 4)
            #expect(e.seq == 5)
        }
        #expect(transport.protocolsSeen.count == 1)
        await workspaces.stop()
        await signaling.stop()
    }

    @Test func theLastReleaseClosesTheSocket() async throws {
        let transport = FakeControlPlaneTransport()
        let pool = pool(transport)
        let a = await pool.session(host: host)
        let b = await pool.session(host: host)
        await a.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(b)
        await a.stop()
        #expect(await pool.openHosts == [host])
        try await b.setPresence(active: true)
        guard case .presenceSet = try await server.next(.presenceSet) else { Issue.record("no presence"); return }
        await b.stop()
        #expect(await pool.openHosts.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await server.next() }
        await #expect(throws: ControlPlaneError.stopped) { try await b.setPresence(active: true) }
    }

    @Test func anotherAccountsMacGetsItsOwnTeamSocket() async throws {
        let transport = FakeControlPlaneTransport()
        let made = Made()
        let pool = pool(transport, made: made)
        let own = await pool.session(host: host)
        let guest = await pool.session(host: host, team: "team_other")
        let ownAgain = await pool.session(host: host, team: "")
        await own.start()
        await guest.start()
        await ownAgain.start()
        var sockets = transport.sockets.makeAsyncIterator()
        _ = try await #require(await sockets.next()).acceptHello()
        _ = try await #require(await sockets.next()).acceptHello()
        await connected(own)
        await connected(guest)
        #expect(made.calls.map(\.1) == [nil, "team_other"])
        #expect(transport.protocolsSeen.count == 2)
        for session in [own, guest, ownAgain] { await session.stop() }
    }

    @Test func signalsReachEveryReader() async throws {
        let transport = FakeControlPlaneTransport()
        let pool = pool(transport)
        let a = await pool.session(host: host)
        let b = await pool.session(host: host)
        await a.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(a)
        let signalsA = await a.signalUpdates()
        let signalsB = await b.signalUpdates()
        let signal = SignalFrame(kind: .ice, session: "sess_1", to: "in_phone01", from: "inst_mac", body: [:])
        try server.send(.signal(signal))
        var ia = signalsA.makeAsyncIterator(), ib = signalsB.makeAsyncIterator()
        #expect(await ia.next()?.session == "sess_1")
        #expect(await ib.next()?.session == "sess_1")
        await a.stop()
        await b.stop()
    }

    @Test func noInstallFailsTheSessionAsUnauthenticated() async throws {
        let pool = HostSocketPool { _, _ in throw ControlPlaneError.unauthenticated }
        let session = await pool.session(host: host)
        await session.start()
        for await state in await session.stateUpdates() {
            if case .failed(let error) = state { #expect(error == .unauthenticated); break }
        }
        await session.stop()
    }
}

extension HostSocketPoolTests {
    @Test func aDeferredSessionLeasesTheSameSocket() async throws {
        let transport = FakeControlPlaneTransport()
        let pool = pool(transport)
        let workspaces = await pool.session(host: host)
        let signaling = pool.deferredSession(host: host)
        await workspaces.start()
        await signaling.start()
        var sockets = transport.sockets.makeAsyncIterator()
        _ = try await #require(await sockets.next()).acceptHello()
        await connected(signaling)
        #expect(transport.protocolsSeen.count == 1)
        await signaling.stop()
        #expect(await pool.openHosts == [host])
        await workspaces.stop()
        #expect(await pool.openHosts.isEmpty)
    }
    /// F1: a lease that stops reading is bounded like the client's own
    /// subscriber: its backlog is dropped and the stream is subscribed again,
    /// so the lease repairs from a fresh snapshot instead of queueing forever.
    @Test func aLeaseThatStopsReadingIsBoundedAndResyncsFromASnapshot() async throws {
        let transport = FakeControlPlaneTransport()
        let pool = pool(transport)
        let lease = await pool.session(host: host)
        await lease.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        await connected(lease)
        let stream = "host:\(host)"
        let updates = await lease.subscribe(stream)
        _ = try await server.next(.subscribe)
        try server.send(snapshot(stream, 0))
        let total: UInt64 = 3000
        for seq in 1...total {
            try server.send(.event(EventFrame(stream: stream, seq: seq, tx: "tx_\(seq)", op: "host.presence.set",
                                              params: .object([:]), actor: [:], origin: .user, at: Int64(seq))))
        }
        guard try await withTimeout(.seconds(5), { try await server.next(.subscribe) }) != nil else {
            Issue.record("no resubscribe for a lease that stopped reading")
            await lease.stop()
            return
        }
        try server.send(snapshot(stream, total))
        var before = 0
        for await update in updates {
            if case .snapshot(let s) = update, s.seq == total { break }
            before += 1
        }
        #expect(before <= 1025, "\(before) updates were queued for the lease before the resync snapshot")
        await lease.stop()
    }
}
