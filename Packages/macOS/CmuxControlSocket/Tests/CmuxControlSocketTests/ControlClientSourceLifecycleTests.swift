import Darwin
import Dispatch
import Foundation
import Testing
@testable import CmuxControlSocket

/// Exercises the same cancellation followed by close used by a CLI connection.
@Suite(.serialized)
struct ControlClientSourceLifecycleTests {
    /// Stresses reuse after read and revocation sources complete cancellation.
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

    /// Revoking an idle connection must still join both descriptor sources.
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

    /// Cancels only after libdispatch registers the real backpressured source.
    @Test(.timeLimit(.minutes(1)))
    func writableSourceCancelsBeforeOwnerClose() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.writer)
            close(pair.reader)
        }
        var sendBuffer: Int32 = 4 * 1024
        try #require(
            setsockopt(
                pair.writer,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBuffer,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        )
        try #require(fcntl(pair.writer, F_SETFL, O_NONBLOCK) == 0)
        let fill = [UInt8](repeating: 0x46, count: 4 * 1024)
        var filledBytes = 0
        while true {
            let written = fill.withUnsafeBytes {
                Darwin.write(pair.writer, $0.baseAddress, $0.count)
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            try #require(written > 0)
            filledBytes += written
            try #require(filledBytes <= 1024 * 1024, "Socket never applied backpressure")
        }
        try #require(filledBytes > 0)

        let registrations = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { registrations.continuation.finish() }
        let writer = ControlClientAsyncWriter(socket: pair.writer, makeWritableSource: { descriptor in
            let source = DispatchSource.makeWriteSource(
                fileDescriptor: descriptor,
                queue: .global(qos: .utility)
            )
            source.setRegistrationHandler {
                registrations.continuation.yield(())
            }
            return source
        })
        // Exercise combined connection teardown: a pending read, generation
        // revocation, and a backpressured write all share the accepted socket.
        let signal = SocketAuthorizationRevocationSignal()
        try #require(signal.readFileDescriptor >= 0)
        let reader = ControlClientAsyncLineReader(
            socket: pair.writer,
            authorizationRevocationSignal: signal
        )
        let reading = Task { await reader.nextLine { true } }
        let pending = Task {
            await writer.writeAll(Data([0x58]))
        }
        var registration = registrations.stream.makeAsyncIterator()
        let registered = await registration.next()
        // This event comes from libdispatch after activation, not from a yield
        // count or elapsed time. An early-cancel-only writer cannot satisfy it.
        pending.cancel()
        signal.revoke()
        #expect(await pending.value == false)
        #expect(await reading.value == nil)
        await reader.cancelAndWait()
        await writer.cancelAndWait()
        #expect(registered != nil)
        #expect(fcntl(pair.writer, F_GETFD) >= 0)
        shutdown(pair.writer, SHUT_RDWR)
    }
}
