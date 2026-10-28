import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextTabs
import CmuxNextWakeups
import Testing

/// A screen tab dragged out of the screen bar hears its events through one input tap intercept that
/// lives for the drag only: Escape, the press after a lost release and the app going
/// inactive return it to its slot, each end runs once, and no end (nor a session the bar drops
/// mid-drag) leaves an intercept. With feature `pointerFrameDrags` its moves light the sidebar on a
/// frame interval's first move and once at the frame.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ScreenDragSessionTests {
    /// How often the session told the bar it ended.
    final class Ends {
        var count = 0
    }

    let services = AppServices(environment: AppEnvironment.current([:]))
    var tap: InputEventTap { services.inputTap }
    /// The session's own center: a resign posted here reaches no other test's observers.
    let center = NotificationCenter()
    let appEvents: AppEvents

    init() {
        appEvents = AppEvents(center: center)
    }

    /// A session for the one screen of a one-screen workspace, from `strip` (nil: one with no tabs; the session
    /// holds it weakly, so a test that needs its window keeps it).
    func makeSession(_ ends: Ends, strip: TabStripView? = nil) -> ScreenDragSession {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let snapshot = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [snapshot]))
        let strip = strip ?? TabStripView(model: TabStripModel(tabs: []), input: tap)
        let session = ScreenDragSession(services: services, screen: ScreenModel(snapshot), daemon: services.daemon,
                                        source: workspace, strip: strip, tabID: CmuxNextTabs.TabID("screen-1"),
                                        appEvents: appEvents)
        session.onEnd = { ends.count += 1 }
        return session
    }

    /// The release commits a move (a new window outside every window), so only the cancelling ends
    /// run here; the release's end is the same `finish` path.
    @Test(arguments: [DragEndPath.escape, .pressAfterLostRelease])
    func everyCancellingEndDropsTheIntercept(_ path: DragEndPath) throws {
        let ends = Ends()
        let base = tap.interceptCounts
        let session = makeSession(ends)
        session.begin()
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        #expect(tap.send(try DragEvents.mouse(.leftMouseDragged)) == .consume, "a responder got the drag's move")
        #expect(tap.send(try DragEvents.key(0, "a")) == .pass, "the drag took a key that is not Escape")
        #expect(tap.send(try path.event()) == path.result, "\(path) was not \(path.result)")
        #expect(ends.count == 1, "\(path) ended the drag \(ends.count) times")
        #expect(tap.interceptCounts == base, "\(path) left an intercept")
        #expect(tap.send(try DragEvents.key()) == .pass, "an ended drag still took Escape")
        #expect(ends.count == 1, "an ended drag ended again")
        withExtendedLifetime(session) {}
    }

    /// Cmd-Tab mid-drag and a release in another app: the tap never hears the release, so the app
    /// going inactive ends the drag (back to its slot), as the tab and link drags end.
    @Test func theAppGoingInactiveEndsTheDragAndDropsTheIntercept() throws {
        let ends = Ends()
        let base = tap.interceptCounts
        let session = makeSession(ends)
        session.begin()
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(ends.count == 1, "the app going inactive ended the drag \(ends.count) times")
        #expect(tap.interceptCounts == base, "the app going inactive left an intercept")
        #expect(appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 0, "the drag kept its resign subscription")
        #expect(tap.send(try DragEvents.key()) == .pass, "an ended drag still took Escape")
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(ends.count == 1, "an ended drag ended again")
        withExtendedLifetime(session) {}
    }

    /// Eight moves in a frame interval light the row under them twice (the first at once, the rest at
    /// the frame); a drag that ended leaves no move waiting.
    @Test func aFrameOfMovesHitTestsTheSidebarTwiceAtMost() throws {
        let frames = PointerFrameTestRig()
        defer { frames.close() }
        services.dragFrameInput = frames.coalescers
        let strip = TabStripView(model: TabStripModel(tabs: []), input: tap)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = strip
        let session = makeSession(Ends(), strip: strip)
        session.begin()
        for step in 1...8 {
            tap.send(try DragEvents.mouse(.leftMouseDragged, at: CGPoint(x: DragEvents.offScreen.x + CGFloat(step), y: DragEvents.offScreen.y)))
        }
        #expect(session.hitTests == 1, "the moves before their frame made \(session.hitTests) hit tests, not 1")
        frames.frame()
        #expect(session.hitTests == 2, "the frame interval made \(session.hitTests) hit tests, not 2")
        for _ in 1...3 { tap.send(try DragEvents.mouse(.leftMouseDragged)) }
        #expect(session.hitTests == 3, "the next interval's first move did not hit-test at once")
        #expect(frames.coalescer.hasPending)
        #expect(tap.send(try DragEvents.key()) == .consume, "Escape went on to a responder")
        #expect(!frames.coalescer.hasPending, "the ended drag left moves waiting")
        frames.frame()
        #expect(session.hitTests == 3, "a waiting move hit-tested after the drag ended")
        withExtendedLifetime((session, strip, window)) {}
    }

    @Test func aSessionDroppedMidDragLeavesNoIntercept() {
        let base = tap.interceptCounts
        var dropped: ScreenDragSession? = makeSession(Ends())
        dropped?.begin()
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        dropped = nil
        #expect(tap.interceptCounts == base, "the dropped session left an intercept")
    }
}
