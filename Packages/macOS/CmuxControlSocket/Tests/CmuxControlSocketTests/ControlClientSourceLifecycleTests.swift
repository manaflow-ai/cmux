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
                        let signal = SocketAuthorizationRevocationSignal()
                        let reader = ControlClientAsyncLineReader(
                            socket: pair.reader,
                            authorizationRevocationSignal: signal
                        )
                        var line: [UInt8] = [112, 105, 110, 103, 10]
                        #expect(write(pair.writer, &line, line.count) == line.count)
                        // A delivered line proves the read source was armed;
                        // do not substitute a delay before teardown.
                        #expect(await reader.nextLine { true } == "ping")
                        // This is TerminalController.handleClientAsync's
                        // teardown order. The reader must wait for
                        // libdispatch to unregister its borrowed descriptor
                        // before the owner closes it.
                        await reader.cancelAndWait()
                        shutdown(pair.reader, SHUT_RDWR)
                        close(pair.reader)
                        close(pair.writer)
                    }
                    return 256
                }
            }
            var completed = 0
            for try await count in group { completed += count }
            #expect(completed == 1_024)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func revocationSourceCancelsBeforeOwnerClose() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        let signal = SocketAuthorizationRevocationSignal()
        let reader = ControlClientAsyncLineReader(
            socket: pair.reader,
            authorizationRevocationSignal: signal
        )
        let pending = Task {
            await reader.nextLine { true }
        }
        signal.revoke()
        #expect(await pending.value == nil)
        await reader.cancelAndWait()
        shutdown(pair.reader, SHUT_RDWR)
        close(pair.reader)
        close(pair.writer)
    }

    @Test(.timeLimit(.minutes(1)))
    func writableSourceCancelsBeforeOwnerClose() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        var sendBuffer = 4 * 1024
        #expect(
            setsockopt(
                pair.writer,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBuffer,
                socklen_t(MemoryLayout<Int>.size)
            ) == 0
        )
        let writer = ControlClientAsyncWriter(socket: pair.writer)
        let pending = Task {
            await writer.writeAll(Data(repeating: 0x58, count: 16 * 1024 * 1024))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        pending.cancel()
        #expect(await pending.value == false)
        await writer.cancelAndWait()
        shutdown(pair.writer, SHUT_RDWR)
        close(pair.writer)
        close(pair.reader)
    }
}
