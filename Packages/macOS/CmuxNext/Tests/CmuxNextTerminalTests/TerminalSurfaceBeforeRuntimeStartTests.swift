import AppKit
import CmuxNextWakeups
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A terminal view made before libghostty's app started gets its surface when the app starts, and then takes keys.
/// Since p02-threads-129 (a649fdca30f) the app starts on its launch's config build (`GhosttyRuntime.start(loadingOn:)`),
/// and `TerminalSurfaceView` made its surface only in `init`: a view made before that start had no surface for its
/// whole life, and its keyDown sent every key nowhere, with no trace (a new terminal that takes no keys). The app makes
/// its services after the start today; a test host, or any launch order that makes a terminal sooner, did not.
///
/// The suite runs in its own process (one per suite), so the shared runtime has not started when the test begins.
@MainActor @Suite(.serialized)
struct TerminalSurfaceBeforeRuntimeStartTests {
    @Test func aViewMadeBeforeTheRuntimeStartsGetsItsSurfaceWhenItStartsAndTakesKeys() async throws {
        let runtime = GhosttyRuntime.shared
        try #require(!runtime.isStarted, "the shared runtime already started in this process: the test needs a fresh one")
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, echoStages: runtime.echoStages, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer {
            io.finish()
            session.close()
        }
        let view = session.surfaceView
        #expect(view.surface == nil, "the view had a surface before libghostty's app started")

        GhosttyRuntime.startedForTests()
        try #require(view.surface != nil, "the view made before the runtime started never got its surface")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = session.view
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "q",
                                                  charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        view.keyDown(with: event)
        let deadline = ContinuousClock.now + .seconds(5)
        while !io.writes.contains(where: { $0.contains(UInt8(ascii: "q")) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(io.writes.contains { $0.contains(UInt8(ascii: "q")) }, "the key typed after the late start reached no terminal: \(io.writes)")
    }
}
