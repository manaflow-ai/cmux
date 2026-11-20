@testable import CmuxNextControl
import Darwin
import Foundation
import Testing

/// NIGHTLY crash 2026-10-30 20:39 (1.0.0-nightly.4115843934401): quitting
/// called `ControlSocketServer.stop()`, which drops its connections and asks
/// each to `close()`. A connection with unsent output waits to drain, but no
/// one held it any more, so it was freed with its read source suspended and
/// libdispatch trapped ("Release of a suspended object").
@Suite(.serialized) struct ControlConnectionDrainTests {
    @Test func aClosedConnectionNobodyHoldsStillDrainsItsOutputThenCloses() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (served, client) = (pair[0], pair[1])
        defer { Darwin.close(client) }
        _ = fcntl(served, F_SETFL, fcntl(served, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(served, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Far more than the socket buffer holds, so close() has to drain.
        let payload = String(repeating: "x", count: 1 << 20)
        let (closed, closedSignal) = AsyncStream<Void>.makeStream()
        do {
            let connection = ControlConnection(
                id: ControlConnectionID(rawValue: 1),
                descriptor: served,
                limits: .init(maxLineBytes: 1024, drainTimeout: .seconds(30))
            )
            connection.onClosed = { closedSignal.finish() }
            connection.start { _ in }
            connection.send(payload)
            connection.close()
        }
        // The test (like a stopped server) holds no reference now.

        let received = await Task.detached { () -> Int in
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(client, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return total }
                total += count
            }
        }.value
        #expect(received == payload.utf8.count + 1)
        for await _ in closed {}
    }
}
