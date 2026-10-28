import CmuxNextCompat
@testable import CmuxNextControl
import Darwin
import Foundation
import Testing

/// A control connection's consumer holds at most `maxQueuedBytes` of lines it has not finished (one
/// line of any size always passes): past it the read source suspends and the socket pushes back on
/// the client. Only the line count bounded it, so 64 lines of up to `maxLineBytes`
/// (4 MiB each) could wait at once.
@Suite(.timeLimit(.minutes(2))) struct ControlConnectionByteBoundTests {
    /// A client writes 100 MB of 64 KiB lines to a consumer that finishes none until it holds the byte
    /// bound, then finishes them all, over and over: it never holds more than the bound, and every
    /// line arrives whole, in order.
    @Test func aStalledConsumerHoldsAtMostTheByteBoundAndLosesNoLine() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (served, client) = (pair[0], pair[1])
        var noSigPipe: Int32 = 1
        setsockopt(served, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(served, F_SETFL, fcntl(served, F_GETFL) | O_NONBLOCK)

        let lineBytes = 64 << 10
        let lines = (100 << 20) / lineBytes
        let bound = 1 << 20
        let limits = ControlConnection.Limits(maxLineBytes: 1 << 20, maxQueuedLines: 64, maxQueuedBytes: bound)
        let connection = ControlConnection(id: ControlConnectionID(rawValue: 1), descriptor: served, limits: limits)
        let (results, result) = AsyncStream<Tally>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connection.start { stream in
            var tally = Tally()
            var held = 0
            for await line in stream {
                if line != Self.line(tally.received, bytes: lineBytes) { tally.mismatches += 1 }
                tally.received += 1
                held += line.utf8.count
                // What the connection handed out and the consumer has not finished: its own and what
                // the stream still holds.
                tally.mostHeld = max(tally.mostHeld, connection.queuedLineBytes)
                // Stalled until the bound: then it finishes every line it holds.
                guard held >= bound else { continue }
                tally.stalls += 1
                while held > 0 {
                    connection.lineConsumed()
                    held -= lineBytes
                }
            }
            result.yield(tally)
            result.finish()
            connection.close()
        }

        let writer = Thread {
            for index in 0..<lines {
                let bytes = Array((Self.line(index, bytes: lineBytes) + "\n").utf8)
                var offset = 0
                while offset < bytes.count {
                    let written = bytes[offset...].withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
                    if written > 0 { offset += written } else if errno != EINTR { return }
                }
            }
            shutdown(client, SHUT_WR)
        }
        writer.start()

        var tallies = results.makeAsyncIterator()
        let tally = try #require(await tallies.next())
        close(client)
        #expect(tally.received == lines, "every line arrives")
        #expect(tally.mismatches == 0, "whole and in order")
        #expect(tally.mostHeld <= bound, "the consumer held \(tally.mostHeld) bytes, past \(bound)")
        #expect(tally.stalls == lines * lineBytes / bound, "the consumer stalled at every bound")
    }

    /// What the consumer saw.
    nonisolated struct Tally: Sendable {
        var received = 0
        var mismatches = 0
        var mostHeld = 0
        var stalls = 0
    }

    /// Line `index`: `bytes` copies of one letter, so a line out of place or cut shows.
    nonisolated static func line(_ index: Int, bytes: Int) -> String {
        String(repeating: Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(index % 26))), count: bytes)
    }
}
