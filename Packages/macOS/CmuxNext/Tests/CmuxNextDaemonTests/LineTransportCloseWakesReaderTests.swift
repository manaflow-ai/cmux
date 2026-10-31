import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// P0 2026-10-30 (v2.2.10-opt): the app closed its control transport while the reader thread waited in a
/// backpressure park, and `close()` only shut the socket down: a parked reader never reads, so it never saw the
/// EOF, never posted `onClose`, and the connection never learned it had ended. It stayed "ready" with a dead
/// transport, every request on it failed "closed by client" at once, and nothing reconnected for 47 minutes.
/// `close()` must end the connection itself: the parked reader wakes, and `onClose` comes once.
@Suite(.timeLimit(.minutes(1))) struct LineTransportCloseWakesReaderTests {
    @Test func closeEndsAConnectionWhoseReaderWaitsForItsConsumer() async throws {
        // 32 event lines of 1 KiB, then the fixture keeps its end open: no EOF comes by itself.
        let script = #"""
        import sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        pad = "x" * 1000
        for i in range(32):
            print('{"event":"title-changed","pad":"%s"}' % pad, flush=True)
        sys.stdin.read()
        """#
        let (parks, parked) = AsyncStream.makeStream(of: Void.self)
        // A consumer that takes nothing: past 4 KiB the reader parks until it does.
        let route = DaemonEventRoute(highWater: 4 << 10, onReaderParked: { parked.yield() })
        let events = DaemonEventStream(route: route)
        let iterator = events.makeAsyncIterator()
        defer { withExtendedLifetime(iterator) {} }

        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let transport = try await LineTransport.open(path: "/tmp/cmux-close-wakes-\(UUID().uuidString).sock", bridge: bridge,
                                                     role: .control, stats: nil)
        let closes = Mutex<[TransportCloseReason]>([])
        transport.start(
            dispatch: EventDispatch(weigh: { _, _ in .light }, readerWait: { route.waitWhileReaderParked() },
                                    wakeReader: { route.wakeParkedReader() }),
            onCausedEvent: { _, line, index, _ in
                route.emit(DaemonEventEnvelope(sequence: index, event: .bell(surface: 1)), bytes: line.count, parksReader: true)
            },
            onClose: { reason in closes.withLock { $0.append(reason) } })

        var parkWaits = parks.makeAsyncIterator()
        _ = await parkWaits.next()
        #expect(route.isReaderParked)

        transport.close()
        var ended: [TransportCloseReason] = []
        for _ in 0..<500 where ended.isEmpty {
            ended = closes.withLock { $0 }
            if ended.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(ended == [.closedByClient], "close() left a parked reader: the connection never ended (\(ended))")
        // Once, even as the reader leaves its read loop after the wake.
        try await Task.sleep(for: .milliseconds(100))
        #expect(closes.withLock { $0 } == [.closedByClient])
    }
}
