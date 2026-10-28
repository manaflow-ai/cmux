@testable import CmuxNextDaemon
import Foundation
import Testing

/// The bounded event pipeline: nothing between the daemon socket and the store grows with
/// a flood. The handshake gate (``EventGate``), the connection's backlog of events no consumer took yet
/// (``DaemonEventRoute``, which `events` reads) and the store's own inbox are each an ``EventInbox``
/// (4096 events, coalescing), and a flood past one ends in one resync.
///
/// The connections are never started: the tests emit on the route, or deliver to the gate, as the
/// transport's reader would.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DaemonStoreTests {
    private static let flood = 100_000
    private static let limit = EventInbox.defaultLimit

    /// Event `index` of a flood no coalescing fits into the limit: titles and scroll offsets of 5000
    /// surfaces (10,000 coalescing keys) and tree changes.
    private static func flooding(_ index: Int) -> DaemonEventEnvelope {
        let surface = SurfaceID(rawValue: UInt64(index % 5000 + 1))
        let event: DaemonEvent = switch index % 3 {
        case 0: .titleChanged(surface: surface, title: "t\(index)")
        case 1: .scrollChanged(surface: surface, offset: UInt64(index), atBottom: false)
        default: .treeChanged(transaction: nil)
        }
        return DaemonEventEnvelope(sequence: UInt64(index), event: event)
    }

    private static func isOverflow(_ envelope: DaemonEventEnvelope) -> Bool {
        if case .overflow = envelope.event { true } else { false }
    }

    private static func connection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-bounded-events-\(UUID().uuidString).sock"),
                         configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
    }

    /// One workspace with one tab on surface 1.
    private static let tree: DaemonTree = {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "t")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }()

    /// 100k events, half before the store takes the connection (the connection's backlog holds them)
    /// and half while its main thread applies nothing (its inbox holds them): each holds at most its
    /// limit, and the one drain fetches one snapshot.
    @Test func aHundredThousandEventFloodStaysBoundedAndResyncsOnce() async throws {
        let connection = Self.connection()
        let store = DaemonStore()
        let snapshots = BoundedEventsSnapshotProbe(tree: Self.tree, barrier: UInt64(Self.flood) + 1)
        let frames = BoundedEventsStalledFrames()
        var requested = frames.requests.makeAsyncIterator()
        for index in 1...Self.flood / 2 { connection.route.emit(Self.flooding(index)) }
        #expect(connection.route.streamBacklog <= Self.limit, "the connection's backlog grew past its limit")
        let driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: frames, snapshot: { snapshots.read() })
        async let ran: Void = store.run(driver: driver)
        // The store took the backlog: one drain frame asked for.
        _ = await requested.next()
        #expect(connection.route.streamBacklog == 0, "the store left events in the connection's backlog")
        for index in (Self.flood / 2 + 1)...Self.flood { connection.route.emit(Self.flooding(index)) }
        #expect(driver.inbox.bufferedCount <= Self.limit, "the store's inbox grew past its limit")
        let epoch = store.connectionEpoch
        store.drain()
        #expect(driver.inbox.bufferedCount == 0)
        let reached = await store.waitApplied(atLeast: snapshots.barrier, since: epoch)
        #expect(reached == .reached, "the resync's snapshot did not apply")
        #expect(snapshots.reads == 1, "the flood fetched \(snapshots.reads) snapshots")
        await connection.close()
        await ran
        #expect(snapshots.reads == 1, "the flood fetched \(snapshots.reads) snapshots")
    }

    /// A reader of `events` that fell 100k events behind gets one overflow in place of what it lost,
    /// and the connection's lifecycle events after it.
    @Test func aStreamReaderBehindAHundredThousandEventsGetsOneOverflow() async throws {
        let connection = Self.connection()
        for index in 1...Self.flood { connection.route.emit(Self.flooding(index)) }
        let lost = DaemonEventEnvelope(sequence: UInt64(Self.flood) + 1, event: .disconnected(reason: "lost"))
        connection.route.emit(lost)
        #expect(connection.route.streamBacklog <= Self.limit, "the connection's backlog grew past its limit")
        await connection.close()
        var read: [DaemonEventEnvelope] = []
        for try await envelope in connection.events { read.append(envelope) }
        #expect(read.count == 2, "read \(read.count) events")
        #expect(read.first.map(Self.isOverflow) == true, "the overflow does not come first")
        #expect(read.last == lost, "the collapse dropped the lifecycle event")
    }

    /// Events during the handshake wait in the gate: a flood holds at most the limit and is released,
    /// after the connected marker, as one overflow; once open, events pass straight through.
    @Test func aFloodDuringTheHandshakeIsHeldBoundedAndReleasedAsOneOverflow() {
        let gate = EventGate()
        var passed: [DaemonEventEnvelope] = []
        for index in 1...Self.flood { gate.deliver(Self.flooding(index)) { passed.append($0) } }
        #expect(passed.isEmpty, "an event passed the closed gate")
        #expect(gate.heldCount <= Self.limit, "the gate held \(gate.heldCount) events")
        let connected = DaemonEventEnvelope(sequence: 0, event: .bell(surface: 1))
        gate.open(first: connected) { passed.append($0) }
        #expect(passed.first == connected)
        #expect(passed.filter { Self.isOverflow($0) }.count == 1)
        #expect(passed.count <= Self.limit + 1)
        #expect(gate.heldCount == 0)
        let after = Self.flooding(Self.flood + 1)
        gate.deliver(after) { passed.append($0) }
        #expect(passed.last == after, "the open gate held an event")
    }

    /// A raw `apps-*` event, as a page relay connection decodes every event: a collapse keeps it.
    private static let unrestorable = DaemonEvent.unknown(name: "apps-flood", payload: .number(1))

    private static func notification() throws -> DaemonEvent {
        let json = #"{"notification":1,"title":"","body":"flood","level":"info","surface":1}"#
        return .notification(try JSONDecoder().decode(DaemonNotification.self, from: Data(json.utf8)))
    }

    /// Floods the backlog of a connection no one reads with `event`, then reads it all after the close.
    private static func readAfterFlooding(_ event: DaemonEvent) async throws -> (held: Int, read: [DaemonEventEnvelope]) {
        let connection = Self.connection()
        for index in 1...Self.flood { connection.route.emit(DaemonEventEnvelope(sequence: UInt64(index), event: event)) }
        let held = connection.route.streamBacklog
        await connection.close()
        var read: [DaemonEventEnvelope] = []
        for try await envelope in connection.events { read.append(envelope) }
        return (held, read)
    }

    private static func lostSome(_ envelope: DaemonEventEnvelope?) -> Bool {
        if case .overflow(let reason)? = envelope?.event { reason.contains("dropped") } else { false }
    }

    /// Events a resync cannot restore survive a collapse only while they fit: 100k of them with no
    /// reader (a page relay's raw stream) hold at most the limit, and the overflow says some were lost.
    @Test func aFloodOfRawEventsWithNoReaderStaysBounded() async throws {
        let (held, read) = try await Self.readAfterFlooding(Self.unrestorable)
        #expect(held <= Self.limit, "the connection's backlog held \(held) events")
        #expect(read.count <= Self.limit, "read \(read.count) events")
        #expect(Self.lostSome(read.first), "the reader was not told it lost events: \(String(describing: read.first))")
    }

    @Test func aFloodOfNotificationsWithNoReaderStaysBounded() async throws {
        let (held, read) = try await Self.readAfterFlooding(try Self.notification())
        #expect(held <= Self.limit, "the connection's backlog held \(held) events")
        #expect(read.count <= Self.limit, "read \(read.count) events")
        #expect(Self.lostSome(read.first), "the reader was not told it lost events: \(String(describing: read.first))")
    }

    /// The handshake gate holds at most its limit of the events a resync cannot restore too.
    @Test func aFloodOfRawEventsDuringTheHandshakeStaysBounded() throws {
        let gate = EventGate()
        let notification = try Self.notification()
        var passed: [DaemonEventEnvelope] = []
        for index in 1...Self.flood {
            let event = index.isMultiple(of: 2) ? Self.unrestorable : notification
            gate.deliver(DaemonEventEnvelope(sequence: UInt64(index), event: event)) { passed.append($0) }
        }
        #expect(gate.heldCount <= Self.limit, "the gate held \(gate.heldCount) events")
        gate.open(first: DaemonEventEnvelope(sequence: 0, event: .bell(surface: 1))) { passed.append($0) }
        #expect(passed.count <= Self.limit + 1, "the gate released \(passed.count) events")
        #expect(Self.lostSome(passed.dropFirst().first), "the reader was not told it lost events")
    }

    /// A full backlog still takes the newest agent status per surface it holds, in place, and the
    /// newest of each lifecycle event, which the store needs after any resync.
    @Test func aFullBacklogKeepsTheNewestAgentStatusAndLifecycleEvent() async throws {
        let connection = Self.connection()
        let surfaces = 8
        // Collapse with events the resync restores, then hold one status per surface.
        for index in 1...Self.limit + 1 { connection.route.emit(DaemonEventEnvelope(sequence: UInt64(index), event: .treeChanged(transaction: nil))) }
        var sequence = UInt64(Self.limit + 1)
        func emit(_ event: DaemonEvent) {
            sequence += 1
            connection.route.emit(DaemonEventEnvelope(sequence: sequence, event: event))
        }
        for surface in 1...surfaces { emit(.agentChanged(AgentStatus(surface: SurfaceID(rawValue: UInt64(surface)), state: .idle, updatedAtMs: 0))) }
        // Fill the rest, then flood statuses of the same surfaces and lifecycle events.
        while connection.route.streamBacklog < Self.limit { emit(Self.unrestorable) }
        for index in 1...Self.flood {
            let surface = SurfaceID(rawValue: UInt64(index % surfaces + 1))
            emit(.agentChanged(AgentStatus(surface: surface, state: .working, updatedAtMs: UInt64(index))))
            if index.isMultiple(of: 1000) { emit(.disconnected(reason: "drop \(index)")) }
        }
        // A new generation, then a reconnect to the same one: handles from before both are invalid.
        let identity = DaemonIdentity(capabilities: [], generation: DaemonGeneration(rawValue: "flood"))
        emit(.connected(identity, generationChanged: true))
        emit(.connected(identity, generationChanged: false))
        #expect(connection.route.streamBacklog <= Self.limit + 2, "the full backlog held \(connection.route.streamBacklog) events")
        await connection.close()
        var read: [DaemonEventEnvelope] = []
        for try await envelope in connection.events { read.append(envelope) }
        let statuses = read.compactMap { envelope -> AgentStatus? in if case .agentChanged(let status) = envelope.event { status } else { nil } }
        #expect(statuses.count == surfaces, "held \(statuses.count) statuses for \(surfaces) surfaces")
        #expect(statuses.allSatisfy { $0.state == .working && $0.updatedAtMs > UInt64(Self.flood - surfaces) }, "a status is not the newest")
        let drops = read.compactMap { envelope -> String? in if case .disconnected(let reason) = envelope.event { reason } else { nil } }
        #expect(drops == ["drop \(Self.flood)"], "kept \(drops.count) disconnects, want only the newest")
        let connects = read.compactMap { envelope -> Bool? in if case .connected(_, let changed) = envelope.event { changed } else { nil } }
        #expect(connects == [true], "kept connects \(connects), want one that says the generation changed")
    }
}

/// The resync's snapshot read of ``DaemonStoreTests``: counts the reads.
@MainActor final class BoundedEventsSnapshotProbe {
    let tree: DaemonTree
    let barrier: UInt64
    private(set) var reads = 0

    init(tree: DaemonTree, barrier: UInt64) {
        (self.tree, self.barrier) = (tree, barrier)
    }

    func read() -> (tree: DaemonTree, barrier: UInt64) {
        reads += 1
        return (tree, barrier)
    }
}

/// The store's frame scheduler for a main thread that applies nothing: records each request and never
/// runs the drain.
final class BoundedEventsStalledFrames: FrameBatchScheduler {
    let requests: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (requests, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        continuation.yield()
    }
}
