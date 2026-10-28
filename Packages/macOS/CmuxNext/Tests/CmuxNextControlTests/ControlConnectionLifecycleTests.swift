@testable import CmuxNextControl
import Darwin
import Foundation
import Testing

/// A control connection's whole life over a socket pair: the client's lines reach the consumer, the
/// replies reach the client before the descriptor closes, and `onClosed` runs exactly once, after the
/// close, whatever comes later (the state behind a checked lock instead of
/// unchecked queue confinement).
@Suite(.timeLimit(.minutes(1))) struct ControlConnectionLifecycleTests {
    @Test func repliesFlushBeforeTheCloseAndOnClosedRunsOnce() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (served, client) = (pair[0], pair[1])
        defer { close(client) }
        // As the server sets up an accepted client.
        var noSigPipe: Int32 = 1
        setsockopt(served, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(served, F_SETFL, fcntl(served, F_GETFL) | O_NONBLOCK)

        let (closes, closed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let connection = ControlConnection(id: ControlConnectionID(rawValue: 1), descriptor: served,
                                           limits: .init(maxLineBytes: 1 << 10), onClosed: { closed.yield() })
        connection.start { lines in
            for await line in lines {
                connection.send("echo \(line)")
                connection.lineConsumed()
            }
            connection.close()
        }
        let request = Array("a\nb\n".utf8)
        #expect(Darwin.send(client, request, request.count, 0) == request.count)
        // The client stops sending: the consumer drains both lines, then closes the connection.
        #expect(shutdown(client, SHUT_WR) == 0)

        var closeEvents = closes.makeAsyncIterator()
        #expect(await closeEvents.next() != nil)
        // The descriptor is closed, so every reply sits in the client's buffer, then end of file.
        #expect(Self.readToEnd(client) == "echo a\necho b\n")

        // Later calls change nothing: the connection is closed. `hangup` returns at once and orders
        // after them on the connection queue, so no second `onClosed` can still be on its way.
        connection.send("late")
        connection.close()
        await connection.hangup()
        closed.finish()
        #expect(await closeEvents.next() == nil)
    }

    /// Everything the client end holds, up to end of file, without waiting (the peer already closed).
    private static func readToEnd(_ descriptor: Int32) -> String {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &chunk, chunk.count, MSG_DONTWAIT)
            if count > 0 {
                bytes.append(contentsOf: chunk.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
