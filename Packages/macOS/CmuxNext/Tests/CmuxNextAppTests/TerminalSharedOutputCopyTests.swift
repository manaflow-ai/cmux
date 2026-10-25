import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import Dispatch
import Foundation
import Testing

/// Output bytes that are a live view of shared memory (the daemon's output ring) reach Ghostty in
/// the seqlock order (D3 lead review of the minor 1 consumer diff): the lane copies them out, then
/// calls the producer's check, then parses the copy. Each check below overwrites the shared bytes
/// first, as a writer that laps the span between the copy and the check would.
@MainActor @Suite(.serialized) struct TerminalSharedOutputCopyTests {
    @Test func aSpanLappedBetweenItsCopyAndItsCheckIsSkippedResyncsOnceAndLeavesNoGarbage() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.parse("ready\r\n")
        let span = SharedSpan("LAPPED-SPAN-TEXT\r\n")
        defer { span.free() }
        let io = h.io
        let lapped: @Sendable () -> Bool = {
            span.overwrite(with: "GARBAGE-GARBAGE!\r\n")
            io.resyncs.withLock { $0 += 1 }
            return false
        }
        io.check = { data in span.isView(data) ? lapped : nil }
        h.io.send(.output(span.data))
        try await h.parse("after\r\n")
        let text = h.session.surfaceView.viewportText() ?? ""
        #expect(text.contains("ready") && text.contains("after"), "\(text)")
        #expect(!text.contains("LAPPED") && !text.contains("GARBAGE"), "a lapped span reached the grid: \(text)")
        #expect(h.io.resyncs.withLock { $0 } == 1, "a skipped span asks for exactly one resync")
    }

    @Test func aSpanIsParsedFromTheCopyTakenBeforeItsCheck() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.parse("ready\r\n")
        let span = SharedSpan("COPIED-SPAN-TEXT\r\n")
        defer { span.free() }
        let overwrittenAfterTheCopy: @Sendable () -> Bool = {
            span.overwrite(with: "GARBAGE-GARBAGE!\r\n")
            return true
        }
        h.io.check = { data in span.isView(data) ? overwrittenAfterTheCopy : nil }
        h.io.send(.output(span.data))
        try await h.parse("after\r\n")
        let text = h.session.surfaceView.viewportText() ?? ""
        #expect(text.contains("COPIED-SPAN-TEXT"), "the copy was not parsed: \(text)")
        #expect(!text.contains("GARBAGE"), "the lane parsed the shared bytes, not its copy: \(text)")
    }

    final class Harness {
        let io = CheckingTerminalIO()
        let session: TerminalSession
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        @MainActor init() throws {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
        }

        @MainActor func close() {
            io.finish()
            window.close()
        }

        /// Sends `text` as output, then a device attributes query; Ghostty's reply comes once the
        /// lane parsed both, so every chunk sent before is parsed too (the lane is serial).
        @MainActor func parse(_ text: String) async throws {
            io.send(.output(Data((text + "\u{1b}[c").utf8)))
            let answered = await Task.detached { [io] in io.waitForWrite(timeout: .seconds(10)) }.value
            try #require(answered, "the output was never parsed")
        }
    }
}

/// Bytes the test owns and can overwrite under the lane, as the ring's writer would. Held as an
/// address (an integer is Sendable); the test's check closure writes them on the lane's queue, after
/// the lane's copy.
nonisolated struct SharedSpan: Sendable {
    let address: UInt
    let count: Int

    init(_ text: String) {
        let utf8 = Array(text.utf8)
        count = utf8.count
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        bytes.copyMemory(from: utf8, byteCount: count)
        address = UInt(bitPattern: bytes)
    }

    private var bytes: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: address) }

    /// A view of the bytes, not a copy (over 14 bytes, so Foundation keeps the pointer).
    var data: Data {
        guard let bytes else { return Data() }
        return Data(bytesNoCopy: bytes, count: count, deallocator: .none)
    }

    func isView(_ data: Data) -> Bool {
        data.withUnsafeBytes { $0.baseAddress.map(UInt.init(bitPattern:)) } == address
    }

    func overwrite(with text: String) {
        let utf8 = Array(text.utf8.prefix(count))
        bytes?.copyMemory(from: utf8, byteCount: utf8.count)
    }

    func free() { bytes?.deallocate() }
}

/// A scripted ``TerminalIO`` with a test-set shared-output check; its writes signal a waiter.
nonisolated final class CheckingTerminalIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    // Test-only: the test thread waits on it for Ghostty's reply to a query.
    private let written = DispatchSemaphore(value: 0)
    private let checks = Mutex<(@Sendable (Data) -> (@Sendable () -> Bool)?)?>(nil)
    let resyncs = Mutex(0)

    var check: (@Sendable (Data) -> (@Sendable () -> Bool)?)? {
        get { checks.withLock { $0 } }
        set { checks.withLock { $0 = newValue } }
    }

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }

    func write(_ data: Data) async { written.signal() }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

    func sharedOutputCheck(_ data: Data) -> (@Sendable () -> Bool)? { check?(data) }

    func waitForWrite(timeout: Duration) -> Bool {
        let nanos = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        return written.wait(timeout: .now() + .nanoseconds(nanos)) == .success
    }
}
