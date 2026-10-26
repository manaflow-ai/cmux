import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextTabs
import Testing

/// A screen tab dragged out of the screen bar hears its events through one input tap intercept that
/// lives for the drag only (p04-input-015): Escape and the press after a lost release return it to its
/// slot, each end runs once, and no end (nor a session the bar drops mid-drag) leaves an intercept.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ScreenDragSessionTests {
    /// How often the session told the bar it ended.
    final class Ends {
        var count = 0
    }

    let services = AppServices(environment: AppEnvironment.current([:]))
    var tap: InputEventTap { services.inputTap }

    /// A session for the one screen of a one-screen workspace, from a strip with no tabs.
    func makeSession(_ ends: Ends) -> ScreenDragSession {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let snapshot = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [snapshot]))
        let strip = TabStripView(model: TabStripModel(tabs: []))
        let session = ScreenDragSession(services: services, screen: ScreenModel(snapshot), daemon: services.daemon,
                                        source: workspace, strip: strip, tabID: CmuxNextTabs.TabID("screen-1"))
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

    @Test func aSessionDroppedMidDragLeavesNoIntercept() {
        let base = tap.interceptCounts
        var dropped: ScreenDragSession? = makeSession(Ends())
        dropped?.begin()
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        dropped = nil
        #expect(tap.interceptCounts == base, "the dropped session left an intercept")
    }
}
