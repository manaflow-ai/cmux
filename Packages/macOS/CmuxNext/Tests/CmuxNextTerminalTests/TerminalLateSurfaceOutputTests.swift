import AppKit
import CmuxNextWakeups
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A terminal made before libghostty's app starts gets its surface when the app starts, takes keys, and shows the
/// output that came for it. Since a649fdca30f the app starts on its launch's config build
/// (`GhosttyRuntime.start(loadingOn:)`), and `TerminalSurfaceView` made its surface only in `init`: a view made before
/// that start had no surface for its whole life, and its keyDown sent every key nowhere, with no trace (a new terminal
/// that takes no keys). Its session also routed the IO's output to no lane, so a fix of the view alone gave a terminal
/// that takes keys and shows nothing (review of 56e51715fe5, B1).
///
/// The shared runtime starts once per process, and other suites in the test process start it; so the check runs in a
/// fresh process (an exit test), where the runtime has not started.
@Suite struct TerminalLateSurfaceOutputTests {
    @Test func aTerminalMadeBeforeTheRuntimeStartsTakesKeysAndShowsItsOutputOnceItStarts() async {
        await #expect(processExitsWith: .success) {
            await LateSurfaceOutputChild.run()
        }
    }
}

/// The exit test's body: exits 0 when every check holds, else the number of the first check that failed.
enum LateSurfaceOutputChild {
    @MainActor static func run() async {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.shared
        guard !runtime.isStarted else { exit(10) }  // the fresh process has a runtime that has not started
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, echoStages: runtime.echoStages, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let view = session.surfaceView
        guard view.surface == nil else { exit(11) }  // no surface before libghostty's app started
        // As a launch window: the terminal is in its window before the start.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        // Output that comes before the start waits for the surface; it is not dropped.
        io.send(.output(Data("early-out\r\n".utf8)))

        GhosttyRuntime.startedForTests()
        guard view.surface != nil else { exit(12) }  // the view made before the start never got its surface

        io.send(.output(Data("late-out\r\n".utf8)))
        guard await until({ (view.viewportText() ?? "").contains("late-out") }) else { exit(13) }  // no output reached the surface
        guard (view.viewportText() ?? "").contains("early-out") else { exit(14) }  // output from before the start was lost

        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                           windowNumber: window.windowNumber, context: nil, characters: "q",
                                           charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12) else { exit(15) }
        view.keyDown(with: event)
        guard await until({ io.writes.contains { $0.contains(UInt8(ascii: "q")) } }) else { exit(16) }  // the key reached no terminal
        io.finish()
        session.close()
        window.close()
        exit(0)
    }

    /// Whether `condition` holds within 5 s; the deadline only ends a failed wait.
    @MainActor private static func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
