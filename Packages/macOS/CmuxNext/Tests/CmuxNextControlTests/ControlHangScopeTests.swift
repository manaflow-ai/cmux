import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextActions
import CmuxNextSettings
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The control socket's accept queue and each connection's queue are hang-watched lanes, one scope per job:
/// an accept pass on `control.accept` with its 1 s budget, each connection job on
/// `control.connection` with 1 s, or 2 s for a job that sends. A scope never nests inside another of its lane,
/// since each queue job opens exactly one.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlHangScopeTests {
    @Test func acceptPassesAndConnectionJobsRunInOneScopeEach() throws {
        let hangs = LaneRecordingHangWatch()
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        var server: ControlSocketServer? = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation),
                                                               router: router, hangs: hangs)
        try server?.start()
        let path = try #require(server?.configuration.path)
        do {
            let client = try LineClient(path: path)
            #expect(client.send("ping") == "PONG")
        }

        // The response reached the client from inside the send job, so that job's scope opened before it did.
        #expect(hangs.entered(lane: "control.accept") >= 1)
        #expect(hangs.deadlines(lane: "control.accept") == [ControlSocketServer.acceptHangDeadline])
        #expect(hangs.deadlines(lane: "control.connection").contains(ControlConnection.readHangDeadline))
        #expect(hangs.deadlines(lane: "control.connection").contains(ControlConnection.writeHangDeadline))
        #expect(hangs.deepestNesting == 1)

        server?.stop()
        server = nil
        #expect(hangs.unregistered.contains("control.accept"))
    }

    @Test func eachConnectionIsItsOwnLane() throws {
        let hangs = LaneRecordingHangWatch()
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation),
                                         router: router, hangs: hangs)
        try server.start()
        defer { server.stop() }
        let first = try LineClient(path: server.configuration.path)
        let second = try LineClient(path: server.configuration.path)
        #expect(first.send("ping") == "PONG")
        #expect(second.send("ping") == "PONG")

        #expect(hangs.lanes.filter { $0 == "control.connection" }.count == 2)
        #expect(hangs.deepestNesting == 1)
    }

    /// The socket file's watch runs on the accept queue: its restore (a bind and a rename on disk) is one
    /// `control.accept` scope, while the first bind, from `start()` off the queue, is in none.
    @Test func aSocketRestoreRunsInAnAcceptScope() async throws {
        let hangs = LaneRecordingHangWatch()
        // Each bind's count of open `control.accept` scopes.
        let (openAtBind, binds) = AsyncStream<Int>.makeStream()
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router,
                                         accept: { Darwin.accept($0, nil, nil) },
                                         bind: { descriptor, address in
                                             binds.yield(hangs.openScopes(lane: "control.accept"))
                                             return address.bind(descriptor)
                                         },
                                         hangs: hangs)
        try server.start()
        defer { server.stop() }
        var seen = openAtBind.makeAsyncIterator()
        let first = await seen.next()
        #expect(first == 0, "start() binds off the accept queue")

        #expect(unlink(server.configuration.path) == 0)
        let restore = await seen.next()
        #expect(restore == 1, "the restore binds inside one accept scope")
        #expect(hangs.deepestNesting == 1)
    }

    @Test func withNoHangWatchNothingRegisters() throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router)
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        #expect(client.send("ping") == "PONG")
    }

    @MainActor @Test func theServiceHandsItsHangWatchToTheServer() throws {
        let hangs = LaneRecordingHangWatch()
        let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: .init(path: temporarySocketPath(), accessMode: .automation),
                                                 identity: testIdentity(), hangs: hangs)
        try service.serve(adopting: nil)
        defer { service.stop() }
        let client = try LineClient(path: service.socketPath)
        #expect(client.send("ping") == "PONG")

        #expect(hangs.lanes.contains("control.accept"))
        #expect(hangs.entered(lane: "control.connection") >= 2)
    }
}

/// A HangWatchScoping that records, per lane, each scope's deadline, and the deepest nesting of scopes on one
/// registration (the accept and connection queues run on different threads at once).
final class LaneRecordingHangWatch: HangWatchScoping {
    private struct State {
        var lanes: [String] = []
        var open: [Int] = []
        var deadlines: [[Duration]] = []
        var unregistered: [String] = []
        var deepest = 0
    }

    private let state = Mutex(State())

    var lanes: [String] { state.withLock { $0.lanes } }
    var unregistered: [String] { state.withLock { $0.unregistered } }
    var deepestNesting: Int { state.withLock { $0.deepest } }

    /// How many scopes are open now on the lanes named `lane`.
    func openScopes(lane: String) -> Int {
        state.withLock { state in
            state.lanes.indices.filter { state.lanes[$0] == lane }.map { state.open[$0] }.reduce(0, +)
        }
    }

    /// How many scopes opened on the lanes named `lane`.
    func entered(lane: String) -> Int { allDeadlines(lane: lane).count }

    /// The distinct deadlines of the scopes on the lanes named `lane`.
    func deadlines(lane: String) -> Set<Duration> {
        Set(allDeadlines(lane: lane))
    }

    private func allDeadlines(lane: String) -> [Duration] {
        state.withLock { state in
            state.lanes.indices.filter { state.lanes[$0] == lane }.flatMap { state.deadlines[$0] }
        }
    }

    func registerLane(_ name: StaticString) -> HangWatch.Registration {
        state.withLock { state in
            state.lanes.append(name.description)
            state.open.append(0)
            state.deadlines.append([])
            return HangWatch.Registration(slot: UInt32(state.lanes.count - 1), generation: 1)
        }
    }

    func unregister(_ registration: HangWatch.Registration) {
        state.withLock { state in
            let name = state.lanes[Int(registration.slot)]
            state.unregistered.append(name)
        }
    }

    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        let slot = Int(registration.slot)
        state.withLock { state in
            state.open[slot] += 1
            state.deadlines[slot].append(deadline)
            state.deepest = max(state.deepest, state.open[slot])
        }
        defer { state.withLock { $0.open[slot] -= 1 } }
        return try body()
    }
}
