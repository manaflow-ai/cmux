import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// principled-audit restoreFrameHold, part 1 (R1, R2): a terminal draws iff its visibility node and its window's node
/// (AppKit's state and the window's occlusion family) are shown. The terminal's pause and `WindowDrawPolicy.isDrawable`
/// (the blank-pane rule's window check) read that one state, and every node edge computes the pause again.
///
/// The first two cases are cp/fix-terminal-stale-hidden-pause's and cp/fix-terminal-pause-on-move's reds (f7716fd526d,
/// 3008cbb86f6, 645199d039e; v2.2.5-opt launch smoke: a second Ctrl-` tab beside Home stayed paused `hidden`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalDrawTruthTests {
    /// The draw policy's seams as a test found them; ``restore()`` puts them back.
    struct Policy {
        let drawsWhenOccluded = WindowDrawPolicy.drawsWhenOccluded
        let onScreen = WindowDrawPolicy.onScreen

        func restore() {
            WindowDrawPolicy.drawsWhenOccluded = drawsWhenOccluded
            WindowDrawPolicy.onScreen = onScreen
        }
    }

    private static func window(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    /// A surface that joined an already hidden container got no viewDidHide; the container's unhide changed no node,
    /// and only a node flip computed the pause again: it stayed paused `hidden`, though nothing hid it.
    @Test func aSurfaceCreatedUnderAHiddenContainerDrawsWhenTheContainerShows() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let policy = Policy()
        defer { policy.restore() }
        WindowDrawPolicy.drawsWhenOccluded = true // a test window is never on screen
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.isHidden = true
        let window = Self.window(container)
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      node: VisibilityNode(root: "tab", own: .visible))
        defer {
            io.finish()
            session.close()
            window.close()
        }
        session.view.frame = container.bounds
        container.addSubview(session.view)
        let surface = session.surfaceView
        try #require(surface.window === window && surface.isHiddenOrHasHiddenAncestor)
        #expect(surface.pause != nil, "a surface under a hidden container draws")

        container.isHidden = false

        #expect(surface.pause == nil, "the container showed and the surface stayed paused \(String(describing: surface.pause))")
    }

    /// A host moved from a hidden pane to a shown one in the same window gets no window move and maybe no unhide: it
    /// must be shown and draw there, and stop when moved back.
    @Test func aHostMovedFromAHiddenPaneToAShownOneDraws() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let policy = Policy()
        defer { policy.restore() }
        WindowDrawPolicy.drawsWhenOccluded = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = Self.window(root)
        let hiddenPane = NSView(frame: root.bounds), shownPane = NSView(frame: root.bounds)
        root.addSubview(hiddenPane)
        root.addSubview(shownPane)
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      node: VisibilityNode(root: "tab", own: .visible))
        defer {
            io.finish()
            session.close()
            window.close()
        }
        session.view.frame = hiddenPane.bounds
        hiddenPane.addSubview(session.view)
        hiddenPane.isHidden = true
        let surface = session.surfaceView
        try #require(surface.isHiddenOrHasHiddenAncestor)
        #expect(surface.pause != nil, "a terminal in a hidden pane draws")

        shownPane.addSubview(session.view) // the same window: a reparent only

        try #require(surface.window === window && !surface.isHiddenOrHasHiddenAncestor)
        #expect(surface.pause == nil, "the terminal moved into a shown pane stayed paused \(String(describing: surface.pause))")
        #expect(surface.isShown, "the terminal moved into a shown pane is not shown")

        hiddenPane.addSubview(session.view)

        #expect(surface.pause != nil, "the terminal moved back into the hidden pane still draws")
        #expect(!surface.isShown, "the terminal moved back into the hidden pane is still shown")
    }

    /// R1: only the terminal read the window's occlusion family; `WindowDrawPolicy.isDrawable`, the blank-pane rule's
    /// window check, did not. A window that one opaque cmux window covers paused its terminal while the invariant still
    /// called it drawable, so the two disagreed. Both read the window's one node now.
    @Test func theBlankPaneRuleAndTheTerminalPauseReadOneWindowState() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let policy = Policy()
        defer { policy.restore() }
        WindowDrawPolicy.drawsWhenOccluded = false
        WindowDrawPolicy.onScreen = { _ in true } // AppKit calls the window visible: only the family covers it
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = Self.window(root)
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      node: VisibilityNode(root: "tab", own: .visible))
        defer {
            io.finish()
            session.close()
            window.close()
        }
        session.view.frame = root.bounds
        root.addSubview(session.view)
        let surface = session.surfaceView
        try #require(surface.pause == nil, "the shown surface in a visible window does not draw")
        #expect(WindowDrawPolicy.isDrawable(window))

        WindowOcclusionFamily.of(window).set(occluded: true)

        #expect(surface.pause == .windowOccluded, "the covered window's terminal still draws")
        #expect(WindowDrawPolicy.isDrawable(window) == (surface.pause == nil),
                "the blank-pane rule calls the covered window drawable while its terminal is paused \(String(describing: surface.pause))")

        WindowOcclusionFamily.of(window).set(occluded: false)

        #expect(surface.pause == nil)
        #expect(WindowDrawPolicy.isDrawable(window))
    }
}
