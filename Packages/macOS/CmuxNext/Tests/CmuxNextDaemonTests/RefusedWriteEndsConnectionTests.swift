import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Follow-up of #28654. Since the heartbeat no longer closes a live daemon's connection, a write the writer
/// refuses (its backlog limit: the daemon stopped reading its socket) must end the connection itself. Before,
/// it only failed the pending requests. The socket stayed open, the reader stayed in `read`, no `onClose` came,
/// the connection kept the dead transport as ready, and the heartbeat saw a live peer and never closed it.
@Suite(.timeLimit(.minutes(1))) struct RefusedWriteEndsConnectionTests {
    @Test func aRefusedWriteEndsTheConnectionAndLeavesNoLivePeer() async throws {
        let daemon = try SlowDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path, writerLimit: 64 << 10)
        defer { transport.close() }
        let closes = Mutex<[TransportCloseReason]>([])
        transport.start(onEvent: { _, _, _ in }, onClose: { reason in closes.withLock { $0.append(reason) } })
        #expect(transport.peerProcessIsAlive, "the daemon (a thread of this process) is alive before the refusal")

        // One request past the writer's limit: the writer refuses it.
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
        #expect(!transport.peerProcessIsAlive, "a closed transport must not report its peer alive (the heartbeat would never close it)")
    }
}
