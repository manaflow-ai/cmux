import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The reader's wait for a consumer behind the event backlog's byte bound (``DaemonEventRoute``) is idle
/// time, not a hang: it runs after the line's `daemon.line` scope closed (HangWatchScoping.swift: "never
/// a wait for a queue slot"), so a designed backpressure wait never shows as a reader hang.
/// A fixture bridge sends 32 event lines of 1 KiB to a route whose high water is
/// 4 KiB, then exits; the consumer takes nothing until the reader parks.
@Suite(.timeLimit(.minutes(1))) struct LineTransportConsumerWaitHangScopeTests {
    @Test func theReaderWaitsForItsConsumerOutsideTheLineScope() async throws {
        let script = #"""
        import sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        pad = "x" * 1000
        for i in range(32):
            print('{"event":"title-changed","pad":"%s"}' % pad, flush=True)
        """#
        let hangs = ScopeStackHangWatch()
        let (parks, parked) = AsyncStream.makeStream(of: [ScopeStackHangWatch.Scope].self)
        let route = DaemonEventRoute(highWater: 4 << 10, onReaderParked: { parked.yield(hangs.open("daemon.line")) })
        let events = DaemonEventStream(route: route)
        var iterator = events.makeAsyncIterator()

        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let transport = try await LineTransport.open(path: "/tmp/cmux-consumer-wait-\(UUID().uuidString).sock", bridge: bridge,
                                                     role: .control, stats: nil, hangs: hangs)
        defer { transport.close() }
        transport.start(
            // Light: each emit runs inline on the reader (its lane stays idle), so the park is owed before the
            // reader's wait after that line; on a heavy lane the wait lags the emits by the lane's backlog,
            // and the fixture's EOF could come first.
            dispatch: EventDispatch(weigh: { _, _ in .light }, readerWait: { route.waitWhileReaderParked() }),
            onCausedEvent: { _, line, index, _ in
                // A bell: the backlog coalesces titles of one surface, so each line stays one event.
                route.emit(DaemonEventEnvelope(sequence: index, event: .bell(surface: 1)),
                           bytes: line.count, parksReader: true)
            },
            onClose: { _ in route.finish() })

        var parkWaits = parks.makeAsyncIterator()
        let openWhileParked = try #require(await parkWaits.next())
        #expect(openWhileParked.isEmpty, "a daemon.line scope was open while the reader waited for its consumer")
        #expect(route.isReaderParked)

        var taken = 0
        while try await iterator.next() != nil { taken += 1 }
        #expect(taken == 32, "every event arrives after the wait")
        #expect(hangs.entered("daemon.line") == 32, "one scope per line, none for the wait")
        #expect(hangs.open("daemon.line").isEmpty)
    }
}
