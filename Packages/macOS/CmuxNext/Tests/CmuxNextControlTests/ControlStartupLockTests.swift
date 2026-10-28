import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// The control socket's startup lock (p08-startup-107, Chrome's ProcessSingletonStartupLock,
/// chrome/browser/process_singleton_startup_lock.cc): the server accepts while the app still registers
/// its methods, checks each peer and parses each line first, holds up to 256 requests and replays them
/// in arrival order at unlock; one more is answered `starting`, and no client is refused a connection.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlStartupLockTests {
    /// The order `test.order` ran its requests in.
    final class Arrivals: Sendable {
        let indices = Mutex<[Int]>([])
    }

    /// A lock that reports each new waiting count on the stream.
    static func observedLock(capacity: Int = ControlStartupLock.defaultCapacity) -> (ControlStartupLock, AsyncStream<Int>) {
        let (stream, sink) = AsyncStream<Int>.makeStream()
        return (ControlStartupLock(capacity: capacity, queued: { sink.yield($0) }), stream)
    }

    static func startedServer(_ lock: ControlStartupLock, mode: ControlAccessMode = .automation,
                              trustedAncestor: pid_t = getpid()) throws -> ControlSocketServer {
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: mode, trustedAncestor: trustedAncestor),
                                         startup: lock)
        try server.start()
        return server
    }

    /// The router with every method group: `test.order` records the order its requests ran in.
    static func router(recording arrivals: Arrivals) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        router.register([
            .async("test.order") { call in
                let index = call.params["index"]?.intValue ?? -1
                arrivals.indices.withLock { $0.append(index) }
                return ["index": JSONValue(index)]
            },
        ])
        return router
    }

    static func orderRequest(_ index: Int) -> String {
        JSONValue.object(["id": JSONValue(index), "method": "test.order", "params": ["index": JSONValue(index)]]).compactText
    }

    /// The acceptance case: 300 clients connect while the app starts, one after another. The first 256
    /// wait and are answered in arrival order once the methods are registered; the other 44 are told
    /// `starting` at once and never run; no connection is refused.
    @Test func threeHundredEarlyClientsAreAnsweredInOrderOrToldStarting() async throws {
        _ = try #require(OpenFileLimit().raise(), "the test holds 600 descriptors")
        let (lock, queued) = Self.observedLock()
        var waits = queued.makeAsyncIterator()
        let server = try Self.startedServer(lock)
        defer { server.stop() }

        var refused = 0
        var waiting: [LineClient] = []
        var starting: [JSONValue] = []
        for index in 0..<300 {
            let client: LineClient
            do {
                client = try LineClient(path: server.configuration.path)
            } catch let error as POSIXError where error.code == .ECONNREFUSED {
                refused += 1
                continue
            }
            client.post(Self.orderRequest(index))
            if index < lock.capacity {
                // Its place in the queue is its arrival order.
                let waitingNow = await waits.next()
                #expect(waitingNow == index + 1, "request \(index) waits")
                waiting.append(client)
            } else {
                starting.append(try JSONValue.parse(Data(client.readLine().utf8)))
            }
        }
        #expect(refused == 0, "no connection is refused while the app starts")
        #expect(waiting.count == 256)
        #expect(starting.count == 44)
        for (offset, answer) in starting.enumerated() {
            #expect(answer["id"] == JSONValue(lock.capacity + offset))
            #expect(answer["ok"] == false)
            #expect(answer["error"]?["code"] == "starting")
            #expect(answer["error"]?["data"]?["not_run"] == true)
            #expect(answer["error"]?["data"]?["limit"] == 256)
            #expect(answer["error"]?["data"]?["retry_after_ms"] == 100)
        }

        let arrivals = Arrivals()
        server.unlock(router: Self.router(recording: arrivals))
        for (index, client) in waiting.enumerated() {
            let answer = try JSONValue.parse(Data(client.readLine().utf8))
            #expect(answer["id"] == JSONValue(index))
            #expect(answer["ok"] == true, "\(answer)")
        }
        #expect(arrivals.indices.withLock { $0 } == Array(0..<256), "replayed in arrival order; the 44 never ran")
        #expect(lock.waitingCount == 0)

        // Open: a request runs at once.
        let late = try LineClient(path: server.configuration.path)
        #expect(try JSONValue.parse(Data(late.send(Self.orderRequest(999)).utf8))["ok"] == true)
    }

    /// Policy before enqueue: a peer the access mode refuses is denied and closed without taking a place.
    @Test func aRefusedPeerIsDeniedWithoutTakingAPlace() throws {
        let lock = ControlStartupLock(capacity: 1)
        let server = try Self.startedServer(lock, mode: .cmuxOnly, trustedAncestor: 999_999)
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        #expect(client.send(Self.orderRequest(0)) == ControlAuthorizer.accessDenied)
        #expect(client.readLine() == "", "closed")
        #expect(lock.waitingCount == 0)
        #expect(!lock.isUnlocked)
    }

    /// The handshake, the liveness probe and a malformed line need no method: they are answered while
    /// the lock holds, and none takes a place.
    @Test func linesThatNeedNoMethodAreAnsweredWhileLocked() throws {
        let lock = ControlStartupLock()
        let server = try Self.startedServer(lock)
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        #expect(client.send("ping") == "PONG")
        #expect(client.send("auth whatever") == "OK: Authentication not required")
        #expect(try JSONValue.parse(Data(client.send(#"{"id":1,"method":"auth.login"}"#).utf8))["ok"] == true)
        #expect(try JSONValue.parse(Data(client.send("{not json").utf8))["error"]?["code"] == "parse_error")
        #expect(try JSONValue.parse(Data(client.send(#"{"id":2}"#).utf8))["error"]?["code"] == "invalid_request")
        #expect(lock.waitingCount == 0)
    }

    /// A server stopped before it unlocked never runs the requests that waited.
    @Test func aStopNeverRunsTheWaitingRequests() async throws {
        let (lock, queued) = Self.observedLock()
        var waits = queued.makeAsyncIterator()
        let server = try Self.startedServer(lock)
        let client = try LineClient(path: server.configuration.path)
        client.post(Self.orderRequest(0))
        let waitingNow = await waits.next()
        #expect(waitingNow == 1)
        server.stop()
        #expect(lock.waitingCount == 0)
        let arrivals = Arrivals()
        server.unlock(router: Self.router(recording: arrivals))
        #expect(arrivals.indices.withLock { $0 }.isEmpty)
    }

    /// The queue itself: one replayed request at a time in arrival order, a request that arrives during
    /// the replay joins the end, one past the capacity is refused at once, and the lock opens when the
    /// queue is empty.
    @Test func theReplayIsSerialAndLateArrivalsJoinTheEnd() async throws {
        let (lock, queued) = Self.observedLock(capacity: 2)
        var waits = queued.makeAsyncIterator()
        let first = Task { await lock.admit() }
        let firstWaits = await waits.next()
        #expect(firstWaits == 1)
        let second = Task { await lock.admit() }
        let secondWaits = await waits.next()
        #expect(secondWaits == 2)
        guard case .refused(let error) = await lock.admit() else {
            Issue.record("one past the capacity is refused")
            return
        }
        #expect(error.code == "starting")
        #expect(error.data?["waiting"] == 2)

        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        lock.unlock(router: router)
        guard case .route(_, let firstTurn?) = await first.value else {
            Issue.record("the first request runs first, with a turn")
            return
        }
        #expect(lock.waitingCount == 1, "the second waits for the first's answer")
        let third = Task { await lock.admit() }
        let thirdWaits = await waits.next()
        #expect(thirdWaits == 2, "an arrival during the replay queues behind it")
        firstTurn.finish()
        firstTurn.finish()  // a second finish changes nothing
        guard case .route(_, let secondTurn?) = await second.value else {
            Issue.record("the second request runs next")
            return
        }
        #expect(lock.waitingCount == 1)
        secondTurn.finish()
        guard case .route(_, let thirdTurn?) = await third.value else {
            Issue.record("the late request runs after the replayed ones")
            return
        }
        thirdTurn.finish()
        guard case .route(_, nil) = await lock.admit() else {
            Issue.record("an open lock routes at once, with no turn")
            return
        }
        #expect(lock.waitingCount == 0)
    }

    /// A replayed request whose turn is dropped unfinished still lets the next one run.
    @Test func aDroppedTurnLetsTheNextRequestRun() async throws {
        let (lock, queued) = Self.observedLock()
        var waits = queued.makeAsyncIterator()
        // The first request's admission (and its turn) ends with its task, unfinished.
        let first = Task { () -> Bool in
            guard case .route = await lock.admit() else { return false }
            return true
        }
        let firstWaits = await waits.next()
        #expect(firstWaits == 1)
        let second = Task { await lock.admit() }
        let secondWaits = await waits.next()
        #expect(secondWaits == 2)
        lock.unlock(router: ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant))
        #expect(await first.value)
        guard case .route(_, let turn?) = await second.value else {
            Issue.record("the second request runs once the first turn is gone")
            return
        }
        turn.finish()
    }
}

/// The launch hands the early server to the service (p08-startup-107): the service unlocks it with its
/// router and the requests that waited run; a server made for another configuration is replaced.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ControlStartupLockServiceTests {
    @MainActor private final class ServeResults {
        var all: [Result<String, any Error>] = []
    }

    @Test func theServiceTakesTheEarlyServerAndReplaysWhatWaited() async throws {
        let path = temporarySocketPath()
        let configuration = ControlSocketServer.Configuration(path: path, accessMode: .automation)
        let (lock, queued) = ControlStartupLockTests.observedLock()
        var waits = queued.makeAsyncIterator()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        let early = try #require(ControlSocketServer.accepting(listener, configuration: configuration, startup: lock, hangs: nil))
        let bind = ControlSocketBind()
        bind.finish(.success(listener), accepting: early)

        // A CLI call at launch: accepted and held, not refused.
        let client = try LineClient(path: path)
        client.post("hello")
        let waitingNow = await waits.next()
        #expect(waitingNow == 1)

        let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: configuration, identity: testIdentity())
        defer { service.stop() }
        let results = ServeResults()
        service.serve(after: bind) { results.all.append($0) }
        #expect(try results.all.first?.get() == path)
        #expect(service.server === early)
        #expect(bind.accepting == nil, "taken")
        // The v1 line reached the service's router (no v1 handler: unknown command), not a refusal.
        #expect(client.readLine().hasPrefix("ERROR: Unknown command 'hello'"))
        #expect(try LineClient(path: path).send("ping") == "PONG")
    }

    @Test func anEarlyServerForAnotherConfigurationIsReplaced() throws {
        let path = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        let other = ControlSocketServer.Configuration(path: path, accessMode: .automation, trustedExecutables: ["/elsewhere/cmux"])
        let early = try #require(ControlSocketServer.accepting(listener, configuration: other, startup: ControlStartupLock(), hangs: nil))
        let bind = ControlSocketBind()
        bind.finish(.success(listener), accepting: early)

        let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: .init(path: path, accessMode: .automation), identity: testIdentity())
        defer { service.stop() }
        let results = ServeResults()
        service.serve(after: bind) { results.all.append($0) }
        #expect(try results.all.first?.get() == path)
        #expect(service.server !== early)
        #expect(!early.isRunning)
        #expect(service.server.isRunning)
        #expect(try LineClient(path: path).send("ping") == "PONG")
    }

    @Test func aDiscardStopsTheEarlyServer() throws {
        let path = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        let early = try #require(ControlSocketServer.accepting(listener, configuration: .init(path: path, accessMode: .automation),
                                                               startup: ControlStartupLock(), hangs: nil))
        let bind = ControlSocketBind()
        bind.finish(.success(listener), accepting: early)
        bind.discard()  // quit before the service served
        #expect(!early.isRunning)
        var info = stat()
        #expect(lstat(path, &info) != 0, "the socket file is removed")
    }
}

extension LineClient {
    /// Sends one line without reading an answer.
    func post(_ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}
