@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The control socket is automation (threading-model.md, "QoS and task priority"): its accept and
/// per-connection queues run at utility, below the person's input. An injected key still runs as
/// input once it reaches the main-thread queue: ahead of other connections' queued requests.
/// The key's event carries the client's send time (bench-typing.py's `timestamp`), so the bench's
/// key latency includes the wait on that utility lane and the main-thread queue; the reply's
/// `injected_at` and `client_to_injection_ms` (``InjectedKeyTime``) separate that wait.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlSocketQoSTests {
    /// What the tests read back from the main thread.
    final class Recorder: Sendable {
        let stallBegan = Mutex<Bool>(false)
        let stallEnd = Mutex<TimeInterval>(0)
        let pendingAtKey = Mutex<Int?>(nil)
    }

    /// A server whose `debug.key` stamps the key with the app's seam (``InjectedKeyTime``, what
    /// `DebugKey.send` builds its event from) and replies with the times; `test.write` is a 2 ms
    /// automation request.
    func makeServer(recording recorder: Recorder, frameSource: any ControlFrameSource = MainQueueFrameSource()) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: true), frameSource: frameSource)
        router.updateCatalog(sampleCatalog())
        let queue = router.workQueue
        router.register([
            .mainActor("debug.key") { call in
                recorder.pendingAtKey.withLock { $0 = queue.stats.pending }
                let time = InjectedKeyTime(params: call.params)
                var report = time.report
                report["event_timestamp"] = .number(time.eventTimestamp)
                return .value(.object(report))
            }.injectingInput(),
            .mainActor("test.write") { _ in
                spin(for: .milliseconds(2))
                return .value(.bool(true))
            },
        ])
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router)
        try server.start()
        return server
    }

    /// Writes one request line and does not wait for its reply.
    func post(_ client: LineClient, _ method: String, _ params: JSONValue = [:]) {
        let request: JSONValue = ["id": "t1", "method": .string(method), "params": params]
        let data = Array((request.compactText + "\n").utf8)
        _ = data.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
    }

    @Test func acceptAndConnectionQueuesRunAtUtility() throws {
        let server = try makeServer(recording: Recorder())
        defer { server.stop() }
        #expect(server.acceptQueueQoS == .utility)

        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        // Never started: the connection owns pair[0] only once it starts, so the test closes it.
        let connection = ControlConnection(id: ControlConnectionID(rawValue: 1), descriptor: pair[0], limits: .init(maxLineBytes: 1 << 10))
        defer { close(pair[0]) }
        #expect(connection.queueQoS == .utility)
    }

    /// Through the socket: 40 connections' automation requests wait in the main-thread queue
    /// (frame-paced, a 1 ms automation budget per frame), then a key arrives on its own connection.
    /// The utility lane hands it over as input: it runs on a main run loop turn with no frame,
    /// ahead of the queued requests.
    @MainActor @Test func anInjectedKeyRunsAheadOfOtherConnectionsQueuedRequests() throws {
        let recorder = Recorder()
        let frames = BudgetedFrameSource(budget: MainFrameBudget(), soonOnRunLoop: true)
        let server = try makeServer(recording: recorder, frameSource: frames)
        defer { server.stop() }
        let queue = server.router.workQueue
        let end = ContinuousClock.now + .seconds(20)

        // The main thread does not turn until all 40 are queued.
        let automation = try (0..<40).map { _ in try LineClient(path: server.configuration.path) }
        for client in automation { post(client, "test.write") }
        while queue.stats.pending < 40, ContinuousClock.now < end { usleep(1_000) }
        #expect(queue.stats.pending == 40)

        let keyClient = try LineClient(path: server.configuration.path)
        post(keyClient, "debug.key", ["key": "a"])
        // No frame fires: only main run loop turns.
        while recorder.pendingAtKey.withLock({ $0 }) == nil, ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        let pendingAtKey = try #require(recorder.pendingAtKey.withLock { $0 }, "the key ran without a frame")
        #expect(pendingAtKey >= 38, "the key ran ahead of the queued automation requests")
        let reply = try JSONValue.parse(Data(keyClient.readLine().utf8))
        #expect(reply["result"]?["injected_at"]?.doubleValue != nil, "the reply carries the key's injection time")

        while queue.stats.pending > 0, ContinuousClock.now < end {
            frames.fire()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        #expect(queue.stats.pending == 0)
        for client in automation {
            let answer = try JSONValue.parse(Data(client.readLine().utf8))
            #expect(answer["result"] == true)
        }
    }

    /// A key sent while the main thread is busy: its event carries the client's send time, so the
    /// wait before injection counts in the bench's key latency, and the reply names that wait
    /// apart (`injected_at` after the stall, `client_to_injection_ms` at least the stall). With no
    /// client time the event carries the injection time.
    @Test func theKeyCarriesTheClientsSendTimeAndTheReplyItsInjectionTime() throws {
        let recorder = Recorder()
        let server = try makeServer(recording: recorder)
        defer { server.stop() }

        _ = Task { @MainActor in
            recorder.stallBegan.withLock { $0 = true }
            spin(for: .milliseconds(300))
            recorder.stallEnd.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        }
        while !recorder.stallBegan.withLock({ $0 }) { usleep(1_000) }

        let client = try LineClient(path: server.configuration.path)
        let sent = ProcessInfo.processInfo.systemUptime
        let stamped = try #require(try client.call("debug.key", ["key": "a", "timestamp": .number(sent)])["result"])
        let stalledUntil = recorder.stallEnd.withLock { $0 }
        #expect(stalledUntil > 0)
        #expect(stamped["event_timestamp"]?.doubleValue == sent, "the event carries the client's send time")
        let injected = try #require(stamped["injected_at"]?.doubleValue)
        #expect(injected >= stalledUntil, "injected when the main thread came free")
        let wait = try #require(stamped["client_to_injection_ms"]?.doubleValue)
        #expect(wait >= 200, "the reply names the wait before injection: \(wait) ms")
        #expect(abs(wait - (injected - sent) * 1000) < 1e-3)

        let unstamped = try #require(try client.call("debug.key", ["key": "b"])["result"])
        #expect(unstamped["event_timestamp"] == unstamped["injected_at"], "with no client time the event carries the injection time")
        #expect(unstamped["client_to_injection_ms"] == .null)
    }
}
