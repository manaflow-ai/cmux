import AppKit
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Exercises the native handoff without the system pasteboard server. The
/// CLI fixture separately proves that these bytes reach the remote PTY owner.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalRemoteFilePasteTests {
    @Test func screenshotUploadFinishesBeforeFollowingReturn() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = FilePasteIO()
        let session = TerminalSession(io: io)
        defer { io.release(); session.close() }
        var events = io.received.makeAsyncIterator()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(session.handOffFilePaste(TerminalPasteboardContents(png: png)))
        guard case .upload(let payload) = await events.next() else {
            Issue.record("The screenshot was not handed to the remote uploader")
            return
        }
        #expect(payload.image?.data == png)
        #expect(payload.image?.mime == "image/png")
        #expect(payload.files == nil)
        session.surfaceView.bridge.takeUnretainedValue().input.send(Data([13]))
        io.release()
        guard case .committed = await events.next() else {
            Issue.record("Typing overtook the remote paste")
            return
        }
        guard case .input(let bytes) = await events.next() else {
            Issue.record("Following input was lost")
            return
        }
        #expect(bytes == Data([13]))
    }

    @Test func filesAreHandedOverWithoutBecomingLocalPathText() async {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = FilePasteIO()
        let session = TerminalSession(io: io)
        defer { io.release(); session.close() }
        var events = io.received.makeAsyncIterator()
        let path = "/tmp/a quoted ' image.png"
        #expect(session.handOffFilePaste(TerminalPasteboardContents(fileURLs: [URL(fileURLWithPath: path)])))
        guard case .upload(let payload) = await events.next() else {
            Issue.record("A file drop became local path text")
            return
        }
        #expect(payload.files == [path])
        #expect(payload.image?.data == nil)
    }

    @Test func textAndLocalTerminalsKeepTheirExistingPastePath() {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let remote = TerminalSession(io: FilePasteIO())
        let localIO = ScriptedTerminalIO()
        let local = TerminalSession(io: localIO)
        defer { remote.close(); local.close(); localIO.finish() }
        #expect(!remote.handOffFilePaste(TerminalPasteboardContents(string: "hello", png: Data([1]))))
        #expect(!local.handOffFilePaste(TerminalPasteboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/a.png")])))
    }
}

private nonisolated final class FilePasteIO: TerminalIO, Sendable {
    enum Received: Sendable {
        case upload(TerminalFilePaste)
        case committed
        case input(Data)
    }

    let uploadsPasteboardFiles = true
    let events = AsyncStream<TerminalIOEvent> { $0.finish() }
    let received: AsyncStream<Received>
    private let receivedContinuation: AsyncStream<Received>.Continuation
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation

    init() {
        (received, receivedContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        (gate, gateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func pasteFiles(_ payload: TerminalFilePaste) async throws {
        receivedContinuation.yield(.upload(payload))
        for await _ in gate { break }
        try Task.checkCancellation()
        receivedContinuation.yield(.committed)
    }

    func release() { gateContinuation.finish() }
    func write(_ data: Data) async { receivedContinuation.yield(.input(data)) }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}
