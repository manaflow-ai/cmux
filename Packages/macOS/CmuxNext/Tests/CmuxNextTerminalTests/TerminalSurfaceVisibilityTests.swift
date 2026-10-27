import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// Recipe R-hide in the terminal (p06-scheduler-215, PL-ghostty): a surface is shown by its node, under its
/// tab's node, not by an ancestor walk. Its tab unselected or its workspace hidden makes it not shown with no
/// AppKit change; AppKit hiding it forwards to the same node; an occluded window keeps it shown (its own
/// occlusion watch pauses the drawing).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalSurfaceVisibilityTests {
    @Test func theSurfaceIsShownByItsTabsNode() {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let tab = VisibilityNode(root: "tab", own: .visible)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: tab)
        defer {
            io.finish()
            session.close()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        let surface = session.surfaceView
        #expect(surface.isShown, "a terminal in a window under a visible tab is not shown")

        tab.set(.hidden)
        #expect(!surface.isShown, "a terminal whose tab hid is still shown")
        tab.set(.occluded)
        #expect(surface.isShown, "an occluded terminal stopped keeping its layout ready")
        tab.set(.visible)
        #expect(surface.isShown)

        session.view.isHidden = true
        #expect(surface.visibilityNode.own == .hidden, "AppKit's hide did not reach the surface's node")
        #expect(!surface.isShown)
        session.view.isHidden = false
        #expect(surface.visibilityNode.own == .visible)
        #expect(surface.isShown)

        tab.set(.hidden)
        session.view.isHidden = true
        session.view.isHidden = false
        #expect(!surface.isShown, "an AppKit unhide showed a terminal whose tab is hidden")
        tab.set(.visible)
        #expect(surface.isShown)
    }

    /// A terminal with no tab (tests, previews) has a root node of its own: it is shown while it is in a window.
    @Test func aSurfaceWithoutATabNodeIsShownInAWindow() {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer {
            io.finish()
            session.close()
        }
        #expect(!session.surfaceView.isShown, "a terminal in no window is shown")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        #expect(session.surfaceView.isShown, "a terminal with no tab node is not shown in its window")
        #expect(session.surfaceView.visibilityNode.parent == nil)
    }
}
