import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Port to feat of the perf test (red there as df2f9a642440fd695fbe37a2): `close()` must end a connection whose
/// reader thread waits for its consumer. A reader that waits never reads the shut socket's EOF, so `onClose` never
/// comes and the owner never learns that its connection ended (v2.2.10-opt P0 2026-10-30: the control connection
/// stayed "ready" with a dead transport for 47 min). feat has two consumers to check:
/// - The control connection hands each event to an unbounded stream, so its reader never waits.
/// - A terminal view's attach connection pushes output into a bounded ``TerminalEventQueue``, whose push waits
///   while the view is more than its high water behind (`TerminalAttachment.detachNow` closes the transport only).
@Suite(.timeLimit(.minutes(1))) struct LineTransportCloseWakesReaderTests {
    /// 32 output lines of 1 KiB in one write, then the fixture keeps its end open: no EOF comes by itself.
    private static let script = #"""
    import sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    pad = "x" * 1000
    sys.stdout.write("".join('{"event":"output","pad":"%s"}\n' % pad for i in range(32)))
    sys.stdout.flush()
    sys.stdin.read()
    """#

    @Test func closeEndsAControlConnectionWithAConsumerThatTakesNothing() async throws {
        let transport = try LineTransport(path: "/tmp/cmux-close-wakes-\(UUID().uuidString).sock",
                                          bridge: DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script]))
        let (events, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        defer { withExtendedLifetime(events) {} }
        let seen = Mutex(0)
        let closes = Mutex<[TransportCloseReason]>([])
        transport.start(onEvent: { _, line, _ in
            sink.yield(line)
            seen.withLock { $0 += 1 }
        }, onClose: { reason in closes.withLock { $0.append(reason) } })
        try await Self.wait { seen.withLock { $0 } >= 32 }
        transport.close()
        try await Self.wait { !closes.withLock { $0 }.isEmpty }
        #expect(closes.withLock { $0 } == [.closedByClient], "close() left the control connection open")
    }

    @Test func closeEndsAnAttachConnectionWhoseReaderWaitsForItsView() async throws {
        let transport = try LineTransport(path: "/tmp/cmux-close-wakes-\(UUID().uuidString).sock",
                                          bridge: DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script]))
        // A view that takes nothing: past 4 KiB of output the reader waits until it does.
        let blocked = Mutex(false)
        let queue = TerminalEventQueue(highWater: 4 << 10, lowWater: 1 << 10, onReaderBlocked: { blocked.withLock { $0 = true } })
        queue.arm()
        let closes = Mutex<[TransportCloseReason]>([])
        transport.start(onEvent: { _, line, _ in queue.push(.output(line, colors: nil)) },
                        onClose: { reason in closes.withLock { $0.append(reason) } })
        try await Self.wait { blocked.withLock { $0 } }

        // What `TerminalAttachment.detachNow` does: it closes the transport while the view is still behind.
        transport.close()
        var ended = false
        for _ in 0..<300 where !ended {
            ended = !closes.withLock { $0 }.isEmpty
            if !ended { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(ended, "close() left an attach reader waiting for its view: the connection never ended")
        queue.cancel()  // releases a reader the close left waiting, so the test's thread ends either way
    }

    private static func wait(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the fixture never reached its state")
    }
}
