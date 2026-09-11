import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IrxLivenessTests {
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let reached = try await withIrxDeadline(.seconds(3), onTimeout: {}) {
            while !Task.isCancelled {
                if await condition() { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        #expect(reached == true, "Expected a real transport event before the deadline")
    }

    @Test func delayedFirstProbeRetriesOnALiveStreamWithoutReplacingQUIC() async throws {
        let host = try await IrxLivenessTestHost.make(behavior: .delayFirstProbe)
        defer { Task { await host.stop() } }
        let session = try await host.dial()
        try await session.connection.startClientKeepalive(interval: .milliseconds(10), deadline: .milliseconds(150)) {
            await host.recordDeath()
        }
        try await waitUntil { host.journal.counterSnapshot()["pong", default: 0] > 0 }
        #expect(await host.probeCount >= 2)
        #expect(await host.connectionCount == 1)
        #expect(await host.deathCount == 0)
        #expect(host.journal.counterSnapshot()["miss"] == 1)
        #expect(await !session.connection.isClosed)
        await session.connection.close(code: .userRequested, origin: .local)
    }

    @Test func suspensionDuringAProbeCannotAccumulateStrikes() async throws {
        let host = try await IrxLivenessTestHost.make(behavior: .delayFirstProbe)
        defer { Task { await host.stop() } }
        let session = try await host.dial()
        try await session.connection.startClientKeepalive(interval: .milliseconds(10), deadline: .milliseconds(100)) {
            await host.recordDeath()
        }
        try await waitUntil { await host.probeCount == 1 }
        await session.connection.setApplicationActive(false)
        // Deliberately outlast both old probe deadlines. This represents time
        // during which iOS is backgrounded and cannot perform application work.
        try await Task.sleep(for: .milliseconds(250))
        #expect(host.journal.counterSnapshot()["miss", default: 0] == 0)
        #expect(await host.deathCount == 0)
        #expect(await host.probeCount == 1)
        #expect(await !session.connection.isClosed)
        await session.connection.setApplicationActive(true)
        try await waitUntil { host.journal.counterSnapshot()["pong", default: 0] > 0 }
        #expect(await host.connectionCount == 1)
        #expect(await host.deathCount == 0)
        await session.connection.close(code: .userRequested, origin: .local)
    }

    @Test func foregroundChecksAnOldHealthySessionAndCoalescesTriggers() async throws {
        let host = try await IrxLivenessTestHost.make(behavior: .waitForRelease)
        defer { Task { await host.stop() } }
        let engine = IrxPeerEngine(config: .init(keepaliveInterval: .seconds(60)), journal: host.journal) {
            try await host.dial(age: .seconds(120))
        }
        let first = try await engine.ensureSession(trigger: "test")
        await engine.setApplicationActive(false)
        await engine.setApplicationActive(true)
        try await waitUntil { await host.probeCount == 1 }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await engine.foregroundKick() } }
        }
        await host.releaseResponse.signal()
        try await waitUntil { host.journal.counterSnapshot()["foreground-session-retained", default: 0] > 0 }
        #expect(await engine.currentSession()?.admit.session == first.admit.session)
        #expect(await host.connectionCount == 1)
        #expect(host.journal.counterSnapshot()["foreground-session-retained"] == 1)
        #expect(await host.probeCount == 1)
        await engine.stop()
    }

    @Test func nativePeerDeathIsDeferredInBackgroundAndRecoveredOnForeground() async throws {
        let host = try await IrxLivenessTestHost.make(behavior: .respond)
        defer { Task { await host.stop() } }
        let engine = IrxPeerEngine(config: .init(keepaliveInterval: .seconds(60)), journal: host.journal) {
            try await host.dial()
        }
        let first = try await engine.ensureSession(trigger: "test")
        await engine.setApplicationActive(false)
        await host.closeFirstConnection()
        try await waitUntil { host.journal.counterSnapshot()["auto-redial-deferred", default: 0] > 0 }
        #expect(await host.connectionCount == 1)
        let started = ContinuousClock.now
        await engine.setApplicationActive(true)
        try await waitUntil {
            guard let current = await engine.currentSession() else { return false }
            return current.admit.session != first.admit.session
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(2))
        host.journal.record("acceptance", "known-closed-resume", ["elapsed": String(describing: elapsed)])
        #expect(await host.connectionCount == 2)
        await engine.stop()
    }

    @Test func silentPeerGetsBoundedFreshProbesBeforeForegroundReplacement() async throws {
        let host = try await IrxLivenessTestHost.make(behavior: .ignoreFirstConnection)
        defer { Task { await host.stop() } }
        let engine = IrxPeerEngine(config: .init(keepaliveInterval: .seconds(60)), journal: host.journal) {
            try await host.dial()
        }
        let first = try await engine.ensureSession(trigger: "test")
        await engine.setApplicationActive(false)
        let started = ContinuousClock.now
        await engine.setApplicationActive(true)
        try await waitUntil {
            guard let current = await engine.currentSession() else { return false }
            return current.admit.session != first.admit.session
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(2))
        host.journal.record("acceptance", "silent-peer-resume", ["elapsed": String(describing: elapsed)])
        #expect(await host.probeCount == 2)
        #expect(await host.connectionCount == 2)
        #expect(await first.connection.isClosed)
        await engine.stop()
    }

    @Test func deferredWarmupResumesWithoutAUserAction() async throws {
        let host = try await IrxLivenessTestHost.make(behavior: .respond)
        defer { Task { await host.stop() } }
        let engine = IrxPeerEngine(journal: host.journal, applicationActive: false) { try await host.dial() }
        await engine.warmUp(trigger: "background-launch")
        #expect(await host.connectionCount == 0)
        await engine.setApplicationActive(true)
        try await waitUntil { await engine.currentSession() != nil }
        #expect(await host.connectionCount == 1)
        await engine.stop()
    }
}

private actor IrxLivenessTestHost {
    enum Behavior: Sendable { case respond, delayFirstProbe, ignoreFirstConnection, waitForRelease }
    nonisolated let journal: IrxJournal
    nonisolated let releaseResponse = IrxAsyncLatch()
    private let server: Endpoint
    private let client: Endpoint
    private let behavior: Behavior
    private var tasks: [Task<Void, Never>] = []
    private var connections: [IrxConnection] = []
    private var delayedLane: IrxLaneStream?
    private var ignoredLanes: [IrxLaneStream] = []
    private(set) var probeCount = 0
    private(set) var deathCount = 0
    var connectionCount: Int { connections.count }

    private init(server: Endpoint, client: Endpoint, behavior: Behavior) {
        self.server = server
        self.client = client
        self.behavior = behavior
        journal = IrxJournal(subsystem: "dev.cmux.tests", category: "liveness",
            journalFileURL: URL(fileURLWithPath: "/tmp/iroh-v2-liveness-test-\(UUID().uuidString).jsonl"))
    }

    static func make(behavior: Behavior) async throws -> IrxLivenessTestHost {
        let server = try await IrxLiveTestSupport.bindLoopback(seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let host = IrxLivenessTestHost(server: server, client: client, behavior: behavior)
        await host.start()
        return host
    }

    func start() {
        tasks.append(Task {
            while let incoming = await server.acceptNext(), !Task.isCancelled {
                do {
                    let native = try await incoming.accept().connect()
                    let connection = IrxConnection(connection: native, role: .acceptor, journal: journal)
                    guard await IrxAdmission.performServer(connection: connection,
                        judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"), journal: journal) != nil else { continue }
                    connections.append(connection)
                    let index = connections.count
                    tasks.append(Task {
                        while let lane = await connection.acceptLane(), !Task.isCancelled {
                            guard lane.descriptor.lane == .keepalive else { continue }
                            tasks.append(Task { await respond(on: lane, connectionIndex: index) })
                        }
                    })
                } catch { return }
            }
        })
    }

    private func respond(on lane: IrxLaneStream, connectionIndex: Int) async {
        do {
            while let ping = try await lane.reader.readControlFrame(IrxPing.self), !Task.isCancelled {
                probeCount += 1
                if behavior == .delayFirstProbe, probeCount == 1 { delayedLane = lane; return }
                if behavior == .ignoreFirstConnection, connectionIndex == 1 { ignoredLanes.append(lane); return }
                if behavior == .waitForRelease { await releaseResponse.wait() }
                try await lane.writer.writeControlFrame(IrxPing(seq: ping.seq, pong: true))
                if let delayed = delayedLane {
                    delayedLane = nil
                    // The old reader has been stopped; this late reply must not
                    // consume or satisfy the new stream's ping.
                    try? await delayed.writer.writeControlFrame(IrxPing(seq: 1, pong: true))
                    await delayed.close()
                }
            }
        } catch { /* Client retires only the timed-out probe lane. */ }
    }

    func dial(age: Duration = .zero) async throws -> IrxClientSession {
        let native = try await client.connect(addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol.alpnData)
        let connection = IrxConnection(connection: native, role: .dialer, journal: journal)
        let (admit, control) = try await IrxAdmission.performClient(connection: connection, grantJWS: "good-grant", journal: journal)
        return IrxClientSession(connection: connection, admit: admit, control: control,
            establishedAt: Date(), establishedAtMonotonic: .now - age)
    }

    func recordDeath() { deathCount += 1 }
    func closeFirstConnection() async { await connections.first?.close(code: .hostShutdown, origin: .local) }
    func stop() async {
        await releaseResponse.signal()
        tasks.forEach { $0.cancel() }
        for connection in connections { await connection.close(code: .hostShutdown, origin: .local) }
        try? await server.close()
        try? await client.close()
    }
}
