import CmuxControlSocket
import Darwin
import Foundation
import os
import Testing

/// A connected `socketpair(2)`; the reader consumes `readEnd`. Close-once
/// tracking matters: tests run in parallel, so double-closing a recycled
/// descriptor number would corrupt another test's fixture.
private final class SocketPairFixture {
    let readEnd: Int32
    private var writeEnd: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        readEnd = fds[0]
        writeEnd = fds[1]
    }

    func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(writeEnd, buffer.baseAddress, buffer.count)
        }
    }

    func write(_ text: String) {
        write(Array(text.utf8))
    }

    func closeWriteEnd() {
        guard writeEnd >= 0 else { return }
        close(writeEnd)
        writeEnd = -1
    }

    deinit {
        close(readEnd)
        closeWriteEnd()
    }
}

@Suite("ControlClientLineReader")
struct ControlClientLineReaderTests {
    @Test func splitsBufferedChunkIntoLines() throws {
        let pair = try SocketPairFixture()
        pair.write("first\nsecond\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "first")
        #expect(reader.nextLine(shouldContinueReading: { true }) == "second")
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func assemblesLineAcrossPartialReads() throws {
        let pair = try SocketPairFixture()
        pair.write("par")
        pair.write("tial\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "partial")
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func crlfIsNotALineTerminator() throws {
        let pair = try SocketPairFixture()
        // Legacy quirk, preserved: Swift strings treat "\r\n" as a single
        // grapheme cluster, so `firstIndex(of: "\n")` never matches it and a
        // CRLF sequence does not terminate a line (clients must send bare
        // "\n"); the CRLF rides along inside the next framed line.
        pair.write("crlf\r\nlf\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "crlf\r\nlf")
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func returnsEmptyAndWhitespaceLinesForCallerToSkip() throws {
        let pair = try SocketPairFixture()
        pair.write("\n  \nok\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "")
        #expect(reader.nextLine(shouldContinueReading: { true }) == "  ")
        #expect(reader.nextLine(shouldContinueReading: { true }) == "ok")
    }

    @Test func dropsChunkThatIsNotValidUTF8() throws {
        let pair = try SocketPairFixture()
        // The legacy loop coalesced an undecodable chunk to "", losing the
        // whole chunk including its newline.
        pair.write([0xFF, 0xFE, 0x0A])
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func pollsOnlyBeforeBlockingReads() throws {
        let pair = try SocketPairFixture()
        pair.write("a\nb\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        var polls = 0
        let countingPoll: () -> Bool = {
            polls += 1
            return true
        }
        // One read(2) delivers both queued lines; the second line must come
        // from the buffer without another poll (legacy inner-loop behavior).
        #expect(reader.nextLine(shouldContinueReading: countingPoll) == "a")
        #expect(polls == 1)
        #expect(reader.nextLine(shouldContinueReading: countingPoll) == "b")
        #expect(polls == 1)
    }

    @Test func stopsWithoutReadingWhenPollReturnsFalse() throws {
        let pair = try SocketPairFixture()
        // No data queued: a read here would block forever, so returning nil
        // proves the poll is consulted before the blocking read.
        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { false }) == nil)
    }

    @Test func discardsTrailingBytesWithoutNewlineAtEOF() throws {
        let pair = try SocketPairFixture()
        pair.write("complete\nincomplete")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "complete")
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func preauthorizationLimitsRejectOversizedFirstLine() throws {
        let pair = try SocketPairFixture()
        pair.write("oversized\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: 4,
                timeoutMilliseconds: 1_000
            )
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func preauthorizationLimitCountsMalformedUTF8Bytes() throws {
        let pair = try SocketPairFixture()
        pair.write([0xFF, 0xFE])
        pair.write("ok\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 3,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: 4,
                timeoutMilliseconds: 1_000
            )
        )

        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func preauthorizationLimitAccumulatesAcrossBlankLines() throws {
        let pair = try SocketPairFixture()
        pair.write("\n\nok\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 2,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: 4,
                timeoutMilliseconds: 1_000
            )
        )

        #expect(reader.nextLine(shouldContinueReading: { true }) == "")
        #expect(reader.nextLine(shouldContinueReading: { true }) == "")
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func preauthorizationDeadlineExpiresWithoutReading() throws {
        let pair = try SocketPairFixture()
        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: 4_096,
                timeoutMilliseconds: 0
            )
        )

        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func preauthorizationDeadlineAppliesToBufferedLines() throws {
        let pair = try SocketPairFixture()
        pair.write("first\nsecond\n")
        pair.closeWriteEnd()
        let now = OSAllocatedUnfairLock(initialState: UInt64(1_000_000))

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: 4_096,
                timeoutMilliseconds: 1
            ),
            monotonicNowNanoseconds: { now.withLock { $0 } }
        )

        #expect(reader.nextLine(shouldContinueReading: { true }) == "first")
        now.withLock { $0 = 2_000_000 }
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func clearingPreauthorizationLimitsAllowsLargerCommands() throws {
        let pair = try SocketPairFixture()
        pair.write("auth\nsubsequent-command\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 6,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: 5,
                timeoutMilliseconds: 1_000
            )
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == "auth")
        reader.clearLimits()
        #expect(reader.nextLine(shouldContinueReading: { true }) == "subsequent-command")
    }
}
