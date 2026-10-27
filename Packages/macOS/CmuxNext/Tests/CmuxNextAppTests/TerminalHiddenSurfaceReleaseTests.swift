import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// A hidden terminal holds no app surface (p01-process-140, feature `terminalHiddenSurfaceRelease`): after its
/// grace the Ghostty surface is freed and a stand-in with none shows; shown again, a fresh surface is built in
/// the show's turn and the owner is asked for a READY. A terminal whose owner keeps no VT state keeps its surface.
@MainActor @Suite(.serialized) struct TerminalHiddenSurfaceReleaseTests {
    @Test func aHiddenTerminalFreesItsSurfaceAndRebuildsItWhenShown() async throws {
        let (session, io) = try Self.session(answersTerminalQueries: true)
        defer { session.close(); io.finish() }
        try await Self.replay(session, io, "hello\r\n")
        let live = session.surfaceView

        session.isRenderingSuspended = true
        #expect(!session.isSurfaceReleased, "the surface went before its grace ended")
        session.surfaceGraceEnded()

        #expect(session.isSurfaceReleased)
        #expect(session.surfaceView !== live, "the released surface's view stayed")
        #expect(session.surfaceView.surface == nil, "a released terminal still holds a Ghostty surface")
        #expect(session.surfaceView.lane == nil)
        #expect(io.resyncs == 0)

        session.isRenderingSuspended = false

        #expect(!session.isSurfaceReleased)
        #expect(session.surfaceView.surface != nil, "showing it did not rebuild the surface in the same turn")
        #expect(session.surfaceView.superview === session.view)
        #expect(session.surfaceReleaseCounts.releases == 1)
        #expect(session.surfaceReleaseCounts.rebuilds == 1)
        let by = ContinuousClock.now.advanced(by: .seconds(5))
        while io.resyncs == 0, ContinuousClock.now < by { await Task.yield() }
        #expect(io.resyncs == 1, "the rebuilt surface never asked its owner for a READY")
    }

    @Test func showingDuringTheGraceKeepsTheSurface() async throws {
        let (session, io) = try Self.session(answersTerminalQueries: true)
        defer { session.close(); io.finish() }
        let live = session.surfaceView
        session.isRenderingSuspended = true
        session.isRenderingSuspended = false
        session.surfaceGraceEnded()
        #expect(!session.isSurfaceReleased)
        #expect(session.surfaceView === live)
    }

    @Test func aTerminalNothingCanRebuildKeepsItsSurface() async throws {
        let (session, io) = try Self.session(answersTerminalQueries: false)
        defer { session.close(); io.finish() }
        let live = session.surfaceView
        session.isRenderingSuspended = true
        session.surfaceGraceEnded()
        #expect(!session.isSurfaceReleased, "a bare PTY's screen would be lost")
        #expect(session.surfaceView === live)
    }

    private static func session(answersTerminalQueries: Bool) throws -> (TerminalSession, ResyncCountingIO) {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ResyncCountingIO(answersTerminalQueries: answersTerminalQueries)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      surfaceRelease: TerminalSurfaceRelease())
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        return (session, io)
    }

    /// Sends `text` as a replay and waits (5 s at most) until the session has content.
    private static func replay(_ session: TerminalSession, _ io: ResyncCountingIO, _ text: String) async throws {
        io.send(.replay(Data(text.utf8)))
        let by = ContinuousClock.now.advanced(by: .seconds(5))
        while !session.surfaceHasContent, ContinuousClock.now < by {
            session.applyEvents()
            await Task.yield()
        }
        try #require(session.surfaceHasContent, "the replay was not applied")
    }
}

/// A scripted owner that counts the READYs asked of it (``TerminalIO/resyncRequested()``).
private nonisolated final class ResyncCountingIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    let answersTerminalQueries: Bool
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let resyncCount = Atomic<Int>(0)

    init(answersTerminalQueries: Bool) {
        self.answersTerminalQueries = answersTerminalQueries
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    var resyncs: Int { resyncCount.load(ordering: .acquiring) }
    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
    func resyncRequested() async { resyncCount.add(1, ordering: .releasing) }
}
