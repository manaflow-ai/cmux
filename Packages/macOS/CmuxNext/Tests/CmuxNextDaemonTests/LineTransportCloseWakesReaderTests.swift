import CmuxNextCompat
import Darwin
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
        // 32 event lines of 1 KiB in ONE write, then the fixture keeps its end open: no EOF comes by itself. The
        // reader takes them in one read, so after a wake it still holds lines in its buffer: a single wake that the
        // next park undoes must not leave the connection open (the reader must leave once the transport ended).
        let script = #"""
        import sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        pad = "x" * 1000
        sys.stdout.write("".join('{"event":"title-changed","pad":"%s"}\n' % pad for i in range(32)))
        sys.stdout.flush()
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

    /// A write the writer refuses (its backlog limit: the daemon stopped reading its socket) fails the pending
    /// requests and must end the connection too: the reader stays in `read` on an open socket otherwise, `onClose`
    /// never comes, the connection keeps the dead transport as ready, and its live peer keeps the heartbeat from
    /// closing it (review of f53d2994889, finding 2).
    @Test func aRefusedWriteEndsTheConnection() async throws {
        let daemon = try DeafDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil, writerLimit: 64 << 10)
        defer { transport.close() }
        let closes = Mutex<[TransportCloseReason]>([])
        transport.start(onCausedEvent: { _, _, _, _ in }, onClose: { reason in closes.withLock { $0.append(reason) } })
        // The first request fills the socket (the daemon reads nothing); the second is past the writer's limit.
        let filler = Data(repeating: 0x20, count: 4 << 20)
        _ = transport.submit(.discard(cmd: "fill", onError: nil)) { _ in filler }
        let refused = transport.submit(.discard(cmd: "refused", onError: nil)) { _ in Data(repeating: 0x20, count: 128 << 10) }
        guard case .failure = refused else {
            Issue.record("the writer took a write past its limit; the test did not reach the refusal")
            return
        }
        var ended: [TransportCloseReason] = []
        for _ in 0..<500 where ended.isEmpty {
            ended = closes.withLock { $0 }
            if ended.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(ended.count == 1, "a refused write left the connection open: no onClose (\(ended))")
        #expect(!transport.peerProcessIsAlive, "a closed transport must not report its peer alive")
    }
}

/// A unix socket served by a thread of the test process that accepts and never reads: its client's writes fill
/// the socket and then queue in the client's writer.
nonisolated final class DeafDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    let path: String
    private let descriptor: Int32
    private let clients = Mutex<[Int32]>([])

    init() throws {
        path = "/tmp/deaf-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                clients.withLock { $0.append(client) }
            }
        }
    }

    func stop() {
        for client in clients.withLock({ $0 }) { close(client) }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
