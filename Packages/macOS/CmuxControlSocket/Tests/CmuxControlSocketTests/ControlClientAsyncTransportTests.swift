import CmuxControlSocket
import Darwin
import Foundation
import os
import Testing

@Suite("Async control-client transport")
struct ControlClientAsyncTransportTests {
    /// Test-only counter used by the partial-line budget scenario. The
    /// reader's continuation is `@Sendable`, so the counter needs a small
    /// synchronous gate even though only the reader task mutates it.
    private final class CallCounter: @unchecked Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)

        func incrementAndRead() -> Int {
            value.withLock {
                $0 += 1
                return $0
            }
        }
    }

    @Test func asyncReaderFramesUtf8WithoutBlockingTheCaller() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }

        let reader = ControlClientAsyncLineReader(socket: pair.reader)
        let firstLine = Task {
            await reader.nextLine(shouldContinueReading: { true })
        }
        let firstPayload = Array("first\nあ\n".utf8)
        firstPayload.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(pair.writer, buffer.baseAddress, buffer.count)
        }

        #expect(await firstLine.value == "first")
        #expect(await reader.nextLine(shouldContinueReading: { true }) == "あ")
    }

    @Test func revocationFinishesAnIdleAsyncReader() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        let signal = SocketAuthorizationRevocationSignal()
        let reader = ControlClientAsyncLineReader(
            socket: pair.reader,
            authorizationRevocationSignal: signal
        )
        let pending = Task {
            await reader.nextLine(shouldContinueReading: { true })
        }
        signal.revoke()
        #expect(await pending.value == nil)
    }

    @Test func socketReceiveTimeoutFinishesAnIdleAsyncReader() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        #expect(
            withUnsafePointer(to: &timeout) { pointer in
                setsockopt(
                    pair.reader,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            } == 0
        )
        let reader = ControlClientAsyncLineReader(socket: pair.reader)
        #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    /// Writes every byte, retrying interruptible failures, so a short or
    /// interrupted write cannot silently leave a reader waiting forever.
    private func writeFully(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Buffering is bounded by bytes, not by a fixed chunk count: many tiny
    /// writes queued ahead of a slow consumer must not kill the connection.
    /// (Each write lands as its own short `read(2)` chunk while nothing is
    /// consuming; a 128-element policy previously overflowed and dropped.)
    @Test func asyncReaderSurvivesManyShortChunksAheadOfTheConsumer() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }

        let reader = ControlClientAsyncLineReader(
            socket: pair.reader,
            maximumBufferedBytes: 64 * 1024
        )
        var expected = ""
        let deadline = Date().addingTimeInterval(5)
        var drainedEveryWrite = true
        for index in 0..<200 {
            let byte: [UInt8] = [UInt8(65 + (index % 26))]
            expected.append(Character(UnicodeScalar(byte[0])))
            guard writeFully(byte, to: pair.writer) else {
                drainedEveryWrite = false
                break
            }
            // Deadline-poll the drain's byte accounting so every write is
            // drained (one queued chunk each) before the next one, keeping
            // the many-short-chunks shape deterministic under load.
            while reader.queuedUnconsumedBytesForTesting < index + 1, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard reader.queuedUnconsumedBytesForTesting == index + 1 else {
                drainedEveryWrite = false
                break
            }
        }
        try #require(drainedEveryWrite)
        #expect(writeFully([0x0A], to: pair.writer))
        #expect(await reader.nextLine(shouldContinueReading: { true }) == expected)
    }

    /// The byte cap covers both parser-owned partial lines and chunks waiting
    /// in the stream; a queued chunk must be rejected when the combined budget
    /// would exceed the connection limit.
    @Test func asyncReaderSharesTheByteCapWithPendingPartialLines() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }

        let reader = ControlClientAsyncLineReader(
            socket: pair.reader,
            maximumBufferedBytes: 8
        )
        let shouldContinueCounter = CallCounter()
        let firstRead = Task {
            return await reader.nextLine {
                let shouldContinueCalls = shouldContinueCounter.incrementAndRead()
                // Consume the first partial chunk, then leave it in the
                // parser so the next write competes for the same byte budget.
                return shouldContinueCalls == 1
            }
        }
        #expect(writeFully(Array("abcd".utf8), to: pair.writer))
        #expect(await firstRead.value == nil)

        // Five queued bytes plus the four pending bytes exceed the eight-byte
        // cap. The drain must close before yielding those five bytes; the old
        // split queue/pending limits incorrectly retained them.
        #expect(writeFully(Array("12345".utf8), to: pair.writer))
        let deadline = Date().addingTimeInterval(5)
        while reader.queuedUnconsumedBytesForTesting < 5, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(reader.queuedUnconsumedBytesForTesting == 0)
    }

    /// `maximumBufferedBytes` is caller-provided; an `Int.max` cap must not
    /// overflow the stream-capacity ceiling math during reader creation.
    @Test func asyncReaderAcceptsAMaximalBufferedByteCap() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }

        let reader = ControlClientAsyncLineReader(
            socket: pair.reader,
            maximumBufferedBytes: .max
        )
        #expect(writeFully(Array("capped\n".utf8), to: pair.writer))
        #expect(await reader.nextLine(shouldContinueReading: { true }) == "capped")
    }

    /// A single control request can exceed 512 KiB (`cmux ssh` workspace
    /// creation carries its inline remote startup script). The reader must
    /// frame it intact rather than dropping chunks once a fixed chunk-count
    /// buffer fills up and then closing the connection.
    @Test func asyncReaderFramesASingleLineLargerThanHalfAMebibyte() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }

        let reader = ControlClientAsyncLineReader(socket: pair.reader)
        let pending = Task {
            await reader.nextLine(shouldContinueReading: { true })
        }
        let line = String(repeating: "a", count: 1_200_000)
        let payload = Array((line + "\n").utf8)
        let writer = pair.writer
        let producer = Thread {
            payload.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(
                        writer,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        return
                    }
                    offset += written
                }
            }
        }
        producer.start()

        let received = await pending.value
        #expect(received?.utf8.count == line.utf8.count)
        #expect(received == line)
    }

    @Test func asyncWriterSuspendsOnlyOnWouldBlockAndPreservesBytes() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        let writer = ControlClientAsyncWriter(socket: pair.writer)
        let payload = Data("response\n".utf8)
        #expect(await writer.writeAll(payload))

        var bytes = [UInt8](repeating: 0, count: payload.count)
        let count = bytes.withUnsafeMutableBufferPointer { buffer in
            Darwin.read(pair.reader, buffer.baseAddress, buffer.count)
        }
        #expect(count == payload.count)
        #expect(Data(bytes) == payload)
    }
}
