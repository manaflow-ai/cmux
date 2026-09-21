import Darwin
import Foundation
import Testing
@testable import CmuxControlSocket

/// Exercises the same cancellation followed by close used by a CLI connection.
@Suite(.serialized)
struct ControlClientSourceLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func repeatedReaderCancellationBeforeOwnerClose() async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<256 {
                        let pair = try UnixSocketFixture.makeSocketPair()
                        let reader = ControlClientAsyncLineReader(socket: pair.reader)
                        defer {
                            // This is TerminalController.handleClientAsync's
                            // teardown order. The reader must wait for
                            // libdispatch to unregister its borrowed
                            // descriptor before the owner closes it.
                            reader.cancelAndWait()
                            shutdown(pair.reader, SHUT_RDWR)
                            close(pair.reader)
                            close(pair.writer)
                        }
                        var line: [UInt8] = [112, 105, 110, 103, 10]
                        #expect(write(pair.writer, &line, line.count) == line.count)
                        // A delivered line proves the read source was armed;
                        // do not substitute a delay before teardown.
                        #expect(await reader.nextLine { true } == "ping")
                    }
                    return 256
                }
            }
            var completed = 0
            for try await count in group { completed += count }
            #expect(completed == 1_024)
        }
    }
}
