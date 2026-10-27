import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextTabs
import CmuxNextWakeups
import Testing

/// A screen tab dragged out of the screen bar hears its events through one input tap intercept that
/// lives for the drag only (p04-input-015): Escape, the press after a lost release and the app going
/// inactive return it to its slot, each end runs once, and no end (nor a session the bar drops
/// mid-drag) leaves an intercept.
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

    /// A session for the one screen of a one-screen workspace, from a strip with no tabs.
    func makeSession(_ ends: Ends) -> ScreenDragSession {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let snapshot = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [snapshot]))
        let strip = TabStripView(model: TabStripModel(tabs: []), input: tap)
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

    @Test func aSessionDroppedMidDragLeavesNoIntercept() {
        let base = tap.interceptCounts
        var dropped: ScreenDragSession? = makeSession(Ends())
        dropped?.begin()
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        dropped = nil
        #expect(tap.interceptCounts == base, "the dropped session left an intercept")
    }
}
