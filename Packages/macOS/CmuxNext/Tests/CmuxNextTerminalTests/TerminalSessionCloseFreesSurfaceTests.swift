import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import IOSurface
import Testing

/// Closing a terminal frees its libghostty surface (renderer and IO threads, Metal resources, the
/// bridge's hook state) at the close, not whenever the last reference goes (cleanup.md, audit batch 7
/// A2 and A10). Before: `TerminalSession.close()` freed nothing; the surface was freed only in
/// `TerminalSurfaceView.deinit`, and that deinit returned at once off the main thread, so a session
/// whose last reference went on another thread (a task that held it) kept its surface, threads and
/// GPU memory for the life of the app. The close also left a running last-frame hold.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalSessionCloseFreesSurfaceTests {
    private func session() throws -> TerminalSession {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let session = TerminalSession(io: ScriptedTerminalIO(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        return session
    }

    @Test func closeFreesTheSurfaceAtOnce() throws {
        let session = try session()
        session.close()
        #expect(session.surfaceView.surface == nil, "close() left the libghostty surface alive until the view's deinit")
    }

    @Test func aSessionReleasedOffTheMainThreadAfterItsCloseLeavesNoLiveSurface() async throws {
        var holder: TerminalSession? = try session()
        weak var view = holder?.surfaceView
        // The surface's output lane outlives the view here, so the test can read whether the surface was freed:
        // the view closes the lane right before ghostty_surface_free, and a closed lane reaches no surface.
        let lane = try #require(holder?.surfaceView.lane)
        holder?.close()
        // The last reference goes on another thread, as when a task held the session.
        let box = UncheckedBox(holder)
        holder = nil
        await Task.detached { box.value = nil }.value
        #expect(view == nil, "the surface view outlived its session's close and release")
        #expect(lane.isClosed, "the closed session's libghostty surface (renderer and IO threads, Metal resources) is still alive")
    }

    @Test func closeEndsTheLastFrameHold() throws {
        let session = try session()
        let surface = try #require(IOSurface(properties: [.width: 16, .height: 16, .bytesPerElement: 4, .pixelFormat: 0x4247_5241]))
        session.frameHold.begin(lastFrame: surface, over: session.surfaceView, in: session.view)
        #expect(session.frameHold.isHolding)
        session.close()
        #expect(!session.frameHold.isHolding, "close() left the last-frame hold painting over a closed terminal")
    }
}

/// Moves the test's last reference to another thread.
private nonisolated final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value?
    init(_ value: Value?) { self.value = value }
}
