@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// The control socket is automation (threading-model.md, "QoS and task priority"): its accept and
/// per-connection queues run at utility, below the person's input. That lane must not reach an
/// injected key: `debug.key` and the benches' injection run on the main thread, as input, and take
/// the key's time there, when it is injected, not when the socket accepted or parsed the request.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlSocketQoSTests {
    /// What the injected `debug.key` body saw on its turn.
    struct Injection: Sendable {
        var onMain: Bool
        var qos: UInt32
        var uptime: TimeInterval
    }

    /// The injections the server's `debug.key` saw, and when the main-thread stall ended.
    final class Recorder: Sendable {
        let injections = Mutex<[Injection]>([])
        let stallEnd = Mutex<TimeInterval>(0)
    }

    func makeServer(recording recorder: Recorder = Recorder()) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: true))
        router.updateCatalog(sampleCatalog())
        router.register([
            // The shape of the app's `debug.key`: a main-actor body that injects input and stamps it.
            .mainActor("debug.key") { _ in
                let uptime = ProcessInfo.processInfo.systemUptime
                let injection = Injection(onMain: Thread.isMainThread, qos: qos_class_self().rawValue, uptime: uptime)
                recorder.injections.withLock { $0.append(injection) }
                return .value(.number(uptime))
            }.injectingInput(),
            .mainActor("test.write") { _ in .value(.bool(Thread.isMainThread)) },
        ])
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router)
        try server.start()
        return server
    }

    @Test func acceptAndConnectionQueuesRunAtUtility() throws {
        let server = try makeServer()
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

    /// The main hop keeps each method's class: requests stay automation, an injected key stays input.
    @Test func mainHopKeepsTheMethodsWorkClass() throws {
        let server = try makeServer()
        defer { server.stop() }
        #expect(server.router.method(named: "test.write")?.workClass == .automation)
        #expect(server.router.method(named: "debug.key")?.workClass == .input)
        let client = try LineClient(path: server.configuration.path)
        #expect(try client.call("test.write")["result"] == true, "a mutation runs on the main thread")
    }

    /// The socket accepts the key while the main thread is busy; the key is stamped when the main
    /// thread injects it, after the stall, on the main thread and not at the socket's utility QoS.
    @Test func injectedKeyIsStampedOnMainAtInjection() throws {
        let recorder = Recorder()
        let server = try makeServer(recording: recorder)
        defer { server.stop() }

        let began = Atomic<Bool>(false)
        _ = Task { @MainActor in
            began.store(true, ordering: .releasing)
            spin(for: .milliseconds(300))
            recorder.stallEnd.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        }
        while !began.load(ordering: .acquiring) { usleep(1_000) }

        let client = try LineClient(path: server.configuration.path)
        let accepted = ProcessInfo.processInfo.systemUptime
        let reply = try client.call("debug.key", ["key": "a"])

        let injection = try #require(recorder.injections.withLock { $0.first })
        let stalledUntil = recorder.stallEnd.withLock { $0 }
        #expect(injection.onMain, "the key is injected on the main thread")
        #expect(injection.qos != QOS_CLASS_UTILITY.rawValue, "the main hop does not run at the socket's utility QoS")
        #expect(stalledUntil > 0 && injection.uptime >= stalledUntil, "stamped at injection, after the main thread came free")
        #expect(injection.uptime - accepted >= 0.2, "not at socket accept, during the stall")
        let replied = try #require(reply["result"]?.doubleValue)
        #expect(abs(replied - injection.uptime) < 1e-6, "the reply carries the time stamped at injection")
    }
}
