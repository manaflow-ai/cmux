@testable import CmuxControlSocket
import Darwin
import Dispatch
import Foundation
import os
import Testing

/// A connected `socketpair(2)`; the reader consumes `readEnd`. Close-once
/// tracking matters: tests run in parallel, so double-closing a recycled
/// descriptor number would corrupt another test's fixture.
private final class SocketPairFixture: @unchecked Sendable {
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

    func writeInBackgroundAndClose(_ text: String) {
        let bytes = Array(text.utf8)
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    Darwin.write(
                        writeEnd,
                        buffer.baseAddress?.advanced(by: offset),
                        buffer.count - offset
                    )
                }
                guard written > 0 else { break }
                offset += written
            }
            closeWriteEnd()
        }
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

    @Test func assemblesMultiByteScalarAcrossPartialReads() throws {
        let pair = try SocketPairFixture()
        pair.write([0xE3, 0x81, 0x82, 0x0A]) // "あ" (U+3042) and newline.
        pair.closeWriteEnd()

        // The reader accepts at most `bufferSize - 1` bytes per read, forcing
        // the scalar to straddle two read(2) calls.
        let reader = ControlClientLineReader(socket: pair.readEnd, bufferSize: 3)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "あ")
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

    @Test func dropsLineThatIsNotValidUTF8() throws {
        let pair = try SocketPairFixture()
        // Malformed input is discarded rather than surfaced as an empty
        // command, without discarding a valid line that follows it.
        pair.write([0xFF, 0xFE, 0x0A] + Array("ok\n".utf8))
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(socket: pair.readEnd)
        #expect(reader.nextLine(shouldContinueReading: { true }) == "ok")
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func dropsMalformedOnlyLineAtEOF() throws {
        let pair = try SocketPairFixture()
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

    @Test func authorizationRevocationStopsIdleReaderWithoutPeerTraffic() throws {
        let pair = try SocketPairFixture()
        let revocationSignal = SocketAuthorizationRevocationSignal()
        let enteredBlockingRead = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let readEnd = pair.readEnd

        DispatchQueue.global(qos: .userInitiated).async {
            let reader = ControlClientLineReader(
                socket: readEnd,
                authorizationRevocationSignal: revocationSignal
            )
            _ = reader.nextLine {
                enteredBlockingRead.signal()
                return true
            }
            finished.signal()
        }

        #expect(enteredBlockingRead.wait(timeout: .now() + 1.0) == .success)
        revocationSignal.revoke()

        let stoppedAfterRevocation = finished.wait(timeout: .now() + 1.0)
        if stoppedAfterRevocation != .success {
            pair.closeWriteEnd()
            _ = finished.wait(timeout: .now() + 1.0)
        }
        #expect(stoppedAfterRevocation == .success)
    }

    @Test func configuredReceiveTimeoutStillStopsIdleReader() throws {
        let pair = try SocketPairFixture()
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        let configured = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                pair.readEnd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        #expect(configured == 0)
        guard configured == 0 else { return }

        let finished = DispatchSemaphore(value: 0)
        let readEnd = pair.readEnd
        DispatchQueue.global(qos: .userInitiated).async {
            let reader = ControlClientLineReader(socket: readEnd)
            _ = reader.nextLine(shouldContinueReading: { true })
            finished.signal()
        }

        let stoppedAfterTimeout = finished.wait(timeout: .now() + 1.0)
        if stoppedAfterTimeout != .success {
            pair.closeWriteEnd()
            _ = finished.wait(timeout: .now() + 1.0)
        }
        #expect(stoppedAfterTimeout == .success)
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

    @Test func codeRouterHandshakeRejectsOversizedUnterminatedLine() throws {
        let pair = try SocketPairFixture()
        pair.writeInBackgroundAndClose(
            #"{"id":1,"method":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
                + String(repeating: "x", count: 5_000)
        )

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func defaultReadBufferCannotOvershootCodeRouterCap() throws {
        let pair = try SocketPairFixture()
        pair.writeInBackgroundAndClose(
            #"{"id":"coderouter-handoff","method":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
                + String(repeating: "x", count: 8_000)
        )
        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func codeRouterRawCapCountsTheNewline() throws {
        let prefix = #"{"method":"coderouter.handoff","padding":""#
        let suffix = #""}"#

        let allowedPair = try SocketPairFixture()
        let allowed = prefix
            + String(repeating: "x", count: 4_095 - prefix.utf8.count - suffix.utf8.count)
            + suffix
        #expect(allowed.utf8.count == 4_095)
        allowedPair.write(allowed + "\n")
        let allowedReader = ControlClientLineReader(
            socket: allowedPair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(allowedReader.nextLine(shouldContinueReading: { true })
            == allowed)

        let rejectedPair = try SocketPairFixture()
        let rejected = allowed + "x"
        #expect(rejected.utf8.count == 4_096)
        rejectedPair.write(rejected + "\n")
        let rejectedReader = ControlClientLineReader(
            socket: rejectedPair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(rejectedReader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func delayedTrailingByteCannotCrossTheRawCap() throws {
        let prefix = #"{"method":"coderouter.handoff.begin","padding":""#
        let suffix = #""}"#
        let line = prefix
            + String(
                repeating: "x",
                count: 4_095 - prefix.utf8.count - suffix.utf8.count
            )
            + suffix
        #expect(line.utf8.count == 4_095)

        let allowedPair = try SocketPairFixture()
        allowedPair.write(line)
        DispatchQueue.global().async {
            allowedPair.write("\n")
            allowedPair.closeWriteEnd()
        }
        let allowedReader = ControlClientLineReader(
            socket: allowedPair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(allowedReader.nextLine(shouldContinueReading: { true }) == line)

        let rejectedPair = try SocketPairFixture()
        rejectedPair.write(line)
        DispatchQueue.global().async {
            rejectedPair.write("x\n")
            rejectedPair.closeWriteEnd()
        }
        let rejectedReader = ControlClientLineReader(
            socket: rejectedPair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(rejectedReader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func codeRouterHandshakeIsOneShotEvenWhenSecondLineIsBuffered() throws {
        let pair = try SocketPairFixture()
        let handoff = #"{"id":1,"method":"coderouter.handoff","params":{"protocolVersion":2}}"#
        pair.write(handoff + "\nsystem.ping\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == handoff)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func codeRouterBeginAllowsOneBoundedCompletionFrame() throws {
        let pair = try SocketPairFixture()
        let begin = #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#
        let complete = #"{"id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"}}"#
        pair.write(begin + "\n" + complete + "\nsystem.ping\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == begin)
        reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 2_000)
        #expect(reader.nextLine(shouldContinueReading: { true }) == complete)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func guessedCompletionCannotFallThroughToASecondFrame() throws {
        let pair = try SocketPairFixture()
        let begin = #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#
        let wrong = #"{"id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#
        let valid = #"{"id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"}}"#
        pair.write(begin + "\n" + wrong + "\n" + valid + "\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == begin)
        reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 2_000)
        #expect(reader.nextLine(shouldContinueReading: { true }) == wrong)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func codeRouterCompletionFrameUsesTheRawCap() throws {
        let pair = try SocketPairFixture()
        let begin = #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#
        let oversizedComplete = #"{"id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(begin + "\n" + oversizedComplete)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == begin)
        reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 2_000)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func codeRouterCompletionUsesOneAbsoluteDeadline() throws {
        let pair = try SocketPairFixture()
        let begin = #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#
        let complete = #"{"id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"}}"#
        pair.write(begin + "\n" + complete + "\n")
        let now = OSAllocatedUnfairLock(initialState: UInt64(1_000_000))

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            monotonicNowNanoseconds: { now.withLock { $0 } },
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == begin)
        reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 2_000)
        now.withLock { $0 = 2_001_000_000 }
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func codeRouterCapAppliesAfterPasswordLoginLine() throws {
        let pair = try SocketPairFixture()
        let login = #"{"id":"login","method":"auth.login","params":{"password":"p"}}"#
        let oversizedArm = #"{"id":"coderouter-handoff-arm","method":"coderouter.handoff.arm","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(login + "\n" + oversizedArm)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == login)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func routeRecognizerDoesNotShrinkOrdinaryV2PayloadLimit() throws {
        let pair = try SocketPairFixture()
        let ordinary = #"{"id":1,"method":"feed.push","params":{"body":""#
            + String(repeating: "x", count: 5_000) + #""}}"#
        pair.write(ordinary + "\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == ordinary)
    }

    @Test func methodTextInsideAValueCannotDisableCodeRouterCap() throws {
        let pair = try SocketPairFixture()
        let handoff = #"{"id":"coderouter-handoff","padding":"\"method\":\"feed.push\"","method":"coderouter.handoff","params":{"protocolVersion":2},"tail":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(handoff)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func bufferedLaterHandoffDoesNotChangeCurrentLineClassification() throws {
        let pair = try SocketPairFixture()
        let ordinary = #"{"id":1,"method":"feed.push","params":{}}"#
        let oversizedHandoff = #"{"id":"coderouter-handoff","method":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(ordinary + "\n" + oversizedHandoff)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 8_192,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == ordinary)
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func escapedMethodKeyFailsClosedAtCodeRouterCap() throws {
        let pair = try SocketPairFixture()
        let handoff = #"{"id":"coderouter-handoff","meth\u006fd":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(handoff)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func duplicateMethodWithCodeRouterRouteStaysCapped() throws {
        let pair = try SocketPairFixture()
        let ambiguous = #"{"id":"coderouter-handoff","method":"feed.push","method":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(ambiguous)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func duplicateCodeRouterMethodAfterTheCapIsRejectedBeforeAppend() throws {
        let pair = try SocketPairFixture()
        let ambiguous = #"{"id":1,"method":"feed.push","params":{"body":""#
            + String(repeating: "x", count: 4_200)
            + #""},"method":"coderouter.handoff"}"#
        #expect(ambiguous.range(of: "coderouter.handoff")?.lowerBound
            .utf16Offset(in: ambiguous) ?? 0 > 4_096)
        pair.writeInBackgroundAndClose(ambiguous)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func escapedDuplicateMethodAfterTheCapIsRejectedBeforeAppend() throws {
        let pair = try SocketPairFixture()
        let ambiguous = #"{"id":1,"method":"feed.push","params":{"body":""#
            + String(repeating: "x", count: 4_200)
            + #""},"method":"coderouter\u002ehandoff.complete"}"#
        pair.writeInBackgroundAndClose(ambiguous)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func methodTextInsideLargeOrdinaryValueRemainsAllowed() throws {
        let pair = try SocketPairFixture()
        let ordinary = #"{"id":1,"method":"feed.push","params":{"body":""#
            + String(repeating: "x", count: 4_200)
            + #"\"method\":\"coderouter.handoff.complete\""}}"#
        pair.writeInBackgroundAndClose(ordinary + "\n")

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == ordinary)
    }

    @Test func trimmedCodeRouterMethodStaysCappedBeforeStrictRejection() throws {
        let pair = try SocketPairFixture()
        let ambiguous = #"{"id":"coderouter-handoff","method":" coderouter.handoff ","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(ambiguous)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test(arguments: ["\u{00A0}", "\u{2003}"])
    func unicodeWhitespacePrefixedCodeRouterRouteStaysCapped(
        prefix: String
    ) throws {
        let pair = try SocketPairFixture()
        let handoff = prefix
            + #"{"id":"coderouter-handoff","method":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(handoff)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func capabilityWrappedCodeRouterRouteStaysCapped() throws {
        let pair = try SocketPairFixture()
        let wrapped = #"  _cmux_capability_v1 opaque-token {"id":"coderouter-handoff","method":"coderouter.handoff","params":{"protocolVersion":2},"padding":""#
            + String(repeating: "x", count: 5_000)
        pair.writeInBackgroundAndClose(wrapped)

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            bufferSize: 128,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func capabilityWrappedOrdinaryRouteKeepsItsPayloadLimit() throws {
        let pair = try SocketPairFixture()
        let wrapped = #"_cmux_capability_v1 opaque-token {"id":1,"method":"feed.push","params":{"body":""#
            + String(repeating: "x", count: 5_000) + #""}}"#
        pair.write(wrapped + "\n")
        pair.closeWriteEnd()

        let reader = ControlClientLineReader(
            socket: pair.readEnd,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        #expect(reader.nextLine(shouldContinueReading: { true }) == wrapped)
    }
}
