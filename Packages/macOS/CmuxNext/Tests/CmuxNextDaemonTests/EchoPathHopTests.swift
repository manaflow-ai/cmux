@testable import CmuxNextDaemon
import Dispatch
import Foundation
import Testing

/// The hops of a daemon event from the socket to the main actor. Before: the
/// reader thread yielded each event into `DaemonConnection.events`, and the store's pump task, a
/// user-initiated job on the Swift cooperative pool, moved it into the inbox, so the echo of a
/// person's action waited behind any pool work. Now the store takes the events on the reader
/// thread (``DaemonConnection/consumeEvents(_:)``): reader -> inbox -> one main run loop hop, and
/// only the events the route's backlog held before the store took the connection pass through the
/// pump, when it attaches.
///
/// The probe records the thread and dispatch queue of every hop; a hop on the pool runs on a queue
/// whose label ends in `.cooperative` (`com.apple.root.user-initiated-qos.cooperative`).
@Suite(.timeLimit(.minutes(1))) struct EchoPathHopTests {
    /// One hop: the event it carried (nil for a frame request) and where it ran.
    struct Hop: Sendable {
        var sequence: UInt64?
        var event: DaemonEvent?
        var thread: String
        var queue: String

        var onPool: Bool { queue.hasSuffix(".cooperative") }
    }

    /// Records each hop on the thread that makes it, in order.
    final class HopProbe: Sendable {
        let hops: AsyncStream<Hop>
        private let continuation: AsyncStream<Hop>.Continuation

        init() {
            (hops, continuation) = AsyncStream.makeStream(of: Hop.self)
        }

        func record(_ envelope: DaemonEventEnvelope?) {
            continuation.yield(Hop(sequence: envelope?.sequence, event: envelope?.event,
                                   thread: Thread.current.name ?? "", queue: String(cString: __dispatch_queue_get_label(nil))))
        }

        func end() {
            continuation.finish()
        }
    }

    /// The store's frame scheduler: records where each drain frame is asked for and never runs it.
    final class FrameProbe: FrameBatchScheduler {
        let probe = HopProbe()

        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            probe.record(nil)
        }
    }

    /// A title of `surface`; the backlog keeps only the newest title of each surface it holds.
    private static func envelope(_ sequence: UInt64, surface: UInt64 = 1) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .titleChanged(surface: SurfaceID(rawValue: surface), title: "t\(sequence)"))
    }

    /// Events the route's backlog holds when a consumer takes over reach it first, in order, on the
    /// attaching task; later ones go straight to it; an event after the end is dropped.
    @Test func theRouteHandsItsBacklogOnBeforeAnyDirectEvent() async throws {
        let route = DaemonEventRoute()
        let probe = HopProbe()
        route.emit(Self.envelope(1, surface: 1))
        route.emit(Self.envelope(2, surface: 2))
        #expect(route.streamBacklog == 2)
        route.attach { probe.record($0) }
        #expect(route.streamBacklog == 0, "the attach left events in the backlog")
        route.emit(Self.envelope(3, surface: 3))
        route.finish()
        route.emit(Self.envelope(4, surface: 4))
        probe.end()
        var delivered: [UInt64] = []
        for await hop in probe.hops { delivered.append(hop.sequence ?? 0) }
        #expect(delivered == [1, 2, 3])
        #expect(route.streamBacklog == 0, "an event after the end reached the backlog")
    }

    /// The echo of a person's divider drag (a daemon event, before its reply) reaches the consumer
    /// on the connection's reader thread: no hop on the cooperative pool between the socket and it.
    @Test func anEchoReachesTheConsumerOnTheReaderThread() async throws {
        let script = #"""
        import json, sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            result = {}
            if frame.get('cmd') == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'echo-hops','capabilities':[]}
            if frame.get('cmd') == 'set-split-ratio':
                print('{"event":"tree-changed","transaction":"key-ack"}', flush=True)
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-echo-hops-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let probe = HopProbe()
        do {
            try await connection.start()
            let consumer = Task { try await connection.consumeEvents { probe.record($0) } }
            var hops = probe.hops.makeAsyncIterator()
            // Buffered before the consumer came: it passes through the consumer's task.
            let connected = try #require(await hops.next())
            if case .connected? = connected.event {} else { Issue.record("the first event was \(String(describing: connected.event))") }
            // The reader routes the echo before the reply, so it has reached the consumer when the reply returns.
            _ = try await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.5))
            let echo = try #require(await hops.next())
            #expect(echo.event == .treeChanged(transaction: "key-ack"))
            #expect(echo.thread.hasPrefix("cmux-tui reader"), "the echo reached the consumer on \(echo.thread) (\(echo.queue)), not the reader")
            #expect(!echo.onPool, "the echo hopped through the cooperative pool (\(echo.queue))")
            #expect((echo.sequence ?? 0) > (connected.sequence ?? .max), "the echo came before the connection's first event")
            await connection.close()
            try await consumer.value
        } catch {
            await connection.close()
            throw error
        }
    }

    /// The store takes over the connection's events: the one buffered before its run passes through
    /// the pump, and a later one asks for its drain frame on the thread that read it.
    @MainActor @Test func theStoreAsksForTheDrainFrameOnTheThreadThatReadTheEvent() async throws {
        // Never started: no socket; the test emits as the reader would.
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-echo-hops.sock"))
        let store = DaemonStore()
        let frames = FrameProbe()
        var hops = frames.probe.hops.makeAsyncIterator()
        connection.route.emit(Self.envelope(1))
        async let ran: Void = store.run(connection: connection, scheduler: frames)
        do {
            _ = try #require(await hops.next(), "the buffered event asked for no frame")
            // The drain took the batch: the next event asks for a frame again.
            let taken = try #require(store.driver).inbox.take()
            #expect(taken.map(\.sequence) == [1])
            let reader = Thread { connection.route.emit(Self.envelope(2)) }
            reader.name = "echo-hops reader"
            reader.qualityOfService = .userInitiated
            reader.start()
            let frame = try #require(await hops.next())
            #expect(frame.thread == "echo-hops reader", "the event reached the inbox on \(frame.thread) (\(frame.queue)), not its reader")
            #expect(!frame.onPool, "the event hopped through the cooperative pool (\(frame.queue))")
            #expect(store.driver?.inbox.bufferedCount == 1)
        } catch {
            await connection.close()
            await ran
            throw error
        }
        await connection.close()
        await ran
    }
}
