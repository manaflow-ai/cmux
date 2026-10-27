import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import IOSurface
import Testing

/// A hidden terminal holds no app surface (p01-process-140, feature `terminalHiddenSurfaceRelease`): after its
/// grace the Ghostty surface is freed and a stand-in with none shows; shown again, a fresh surface is built in
/// the show's turn and the owner is asked for the whole screen again (a fresh attach). Output before that screen
/// never lands on the fresh surface; a terminal whose owner cannot resend its screen, or whose surface holds a
/// selection or a scrolled-back viewport, keeps its surface.
@MainActor @Suite(.serialized) struct TerminalHiddenSurfaceReleaseTests {
    @Test func aHiddenTerminalFreesItsSurfaceAndRebuildsItWhenShown() async throws {
        let (session, io) = try Self.session()
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
        #expect(io.refreshes == 0)

        session.isRenderingSuspended = false

        #expect(!session.isSurfaceReleased)
        #expect(session.surfaceView.surface != nil, "showing it did not rebuild the surface in the same turn")
        #expect(session.surfaceView.superview === session.view)
        #expect(session.surfaceReleaseCounts.releases == 1)
        #expect(session.surfaceReleaseCounts.rebuilds == 1)
        try await Self.waitForRefresh(io)
    }

    @Test func outputBeforeTheResentScreenKeepsTheLastFrameUp() async throws {
        let (session, io) = try Self.session()
        defer { session.close(); io.finish() }
        try await Self.replay(session, io, "hello\r\n")
        session.isRenderingSuspended = true
        session.surfaceGraceEnded()
        try #require(session.isSurfaceReleased)
        session.surfaceRelease?.frame = try Self.frame()

        session.isRenderingSuspended = false
        #expect(session.frameHold.isHolding, "the rebuilt surface showed without its last frame")
        try await Self.waitForRefresh(io)

        // The stream goes on before the owner's screen comes: a mid-stream fragment.
        io.send(.output(Data("\u{1b}[2;5Hfragment".utf8)))
        io.send(.status(.restoring)) // routed after it
        try await Self.applyUntil(session) { session.model.connection == .restoring }
        #expect(!session.surfaceHasContent, "a fragment before the resent screen was parsed into the fresh surface")
        #expect(session.frameHold.isHolding, "a fragment before the resent screen ended the last-frame hold")

        io.send(.replay(Data("hello\r\nworld\r\n".utf8)))
        try await Self.applyUntil(session) { session.surfaceHasContent }
    }

    @Test func aTerminalThatExitsWhileReleasedShowsItsFinalScreen() async throws {
        let (session, io) = try Self.session()
        defer { session.close(); io.finish() }
        try await Self.replay(session, io, "build\r\n")
        session.isRenderingSuspended = true
        session.surfaceGraceEnded()
        try #require(session.isSurfaceReleased)

        // The build finishes while hidden: its last output is not parsed, then the process exits.
        io.send(.output(Data("error: 3 failed\r\n".utf8)))
        io.send(.status(.exited))
        io.send(.exited)
        try await Self.applyUntil(session) { session.model.hasExited }
        #expect(session.isSurfaceReleased, "a hidden terminal rebuilt its surface for an exit")

        session.isRenderingSuspended = false
        try await Self.waitForRefresh(io) // an exited terminal still attaches once for its final screen
        io.send(.replay(Data("build\r\nerror: 3 failed\r\n".utf8)))
        try await Self.applyUntil(session) { session.surfaceHasContent }
        #expect(session.model.hasExited)
    }

    @Test func showingDuringTheGraceKeepsTheSurface() async throws {
        let (session, io) = try Self.session()
        defer { session.close(); io.finish() }
        let live = session.surfaceView
        session.isRenderingSuspended = true
        session.isRenderingSuspended = false
        session.surfaceGraceEnded()
        #expect(!session.isSurfaceReleased)
        #expect(session.surfaceView === live)
    }

    @Test func aTerminalNothingCanRebuildKeepsItsSurface() async throws {
        let (session, io) = try Self.session(resendsScreen: false)
        defer { session.close(); io.finish() }
        let live = session.surfaceView
        session.isRenderingSuspended = true
        session.surfaceGraceEnded()
        #expect(!session.isSurfaceReleased, "a screen nothing can send again would be lost")
        #expect(session.surfaceView === live)
    }

    @Test func aScrolledBackTerminalKeepsItsSurface() async throws {
        let (session, io) = try Self.session()
        defer { session.close(); io.finish() }
        try await Self.replay(session, io, "hello\r\n")
        let live = session.surfaceView
        session.model.scrollbar = TerminalScrollbar(totalRows: 500, offsetRows: 100, visibleRows: 24)
        session.isRenderingSuspended = true
        session.surfaceGraceEnded()
        #expect(!session.isSurfaceReleased, "a rebuilt surface would lose the scroll position")
        #expect(session.surfaceView === live)

        // At the bottom it goes after the grace.
        session.isRenderingSuspended = false
        session.model.scrollbar = TerminalScrollbar(totalRows: 500, offsetRows: 476, visibleRows: 24)
        session.isRenderingSuspended = true
        session.surfaceGraceEnded()
        #expect(session.isSurfaceReleased)
    }

    private static func session(resendsScreen: Bool = true) throws -> (TerminalSession, RefreshCountingIO) {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = RefreshCountingIO(resendsScreen: resendsScreen)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      surfaceRelease: TerminalSurfaceRelease())
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        return (session, io)
    }

    private static func frame() throws -> TerminalLastFrame {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return TerminalLastFrame(surface: surface)
    }

    /// Sends `text` as a replay and waits (5 s at most) until the session has content.
    private static func replay(_ session: TerminalSession, _ io: RefreshCountingIO, _ text: String) async throws {
        io.send(.replay(Data(text.utf8)))
        try await applyUntil(session) { session.surfaceHasContent }
    }

    /// Applies the events loop's changes until `done` (5 s at most).
    private static func applyUntil(_ session: TerminalSession, _ done: () -> Bool) async throws {
        let by = ContinuousClock.now.advanced(by: .seconds(5))
        while !done(), ContinuousClock.now < by {
            session.applyEvents()
            await Task.yield()
        }
        try #require(done(), "the events loop did not get there")
    }

    private static func waitForRefresh(_ io: RefreshCountingIO) async throws {
        let by = ContinuousClock.now.advanced(by: .seconds(5))
        while io.refreshes == 0, ContinuousClock.now < by { await Task.yield() }
        try #require(io.refreshes == 1, "the rebuilt surface never asked its owner for the whole screen")
    }
}

/// A scripted owner that counts the whole screens asked of it (``TerminalIO/refreshRequested()``).
private nonisolated final class RefreshCountingIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    let resendsScreen: Bool
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let refreshCount = Atomic<Int>(0)

    init(resendsScreen: Bool) {
        self.resendsScreen = resendsScreen
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    var refreshes: Int { refreshCount.load(ordering: .acquiring) }
    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
    func refreshRequested() async { refreshCount.add(1, ordering: .releasing) }
}
