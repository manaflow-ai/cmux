import AppKit
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextSidebar/Views sweep, first half (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9): one case per migrated owner class.
/// - Hidden: the Priority view's minute redraw is a deadline aligned on the sidebar's node, and a minute that comes
///   while the sidebar is hidden redraws once, on show, and wakes no more until then (R-timer, rule 4).
/// - Visible: a shown sidebar's minute redraws in its wake and arms the next one.
/// - Service: the container's presentation and width observation applies as one posted task on the scheduler,
///   off the change's turn, with no window (a model side effect runs while hidden, rule 3).
/// - Person: a person's width change applies in the input-response pass, before the commit (rule 2). The spring-load
///   hover of an external tab drag is a userBlocking deadline, cancelled when the tab leaves the row (R-timer, rule 6).
/// - Person and window input state: the list ends a held gesture on the app's resign-active through the injected
///   AppEvents and on its window's resign-key through WindowEvents, with no NotificationCenter observer of its own.
/// - The key-window repaint is one WindowEvents observer per window and notice, however many views follow it.
@MainActor @Suite(.serialized) struct SidebarViewsSchedulerSweepTests {
    private static func working() -> SidebarPriorityPanel {
        SidebarPriorityPanel(entries: [SidebarPriorityEntry(id: "chat", title: "chat", state: .working(since: Date()))])
    }

    // MARK: Hidden and visible: the Priority view's minute (R-timer)

    @Test func aHiddenSidebarsMinuteRedrawsOnceOnShow() {
        let rig = MainDeadlineRig()
        let node = VisibilityNode(root: "sidebar.list", own: .hidden)
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.follow(rig.deadlines, visibility: node)
        #expect(!rig.hasArmedWake, "a panel with no working chip armed its minute")

        view.show(Self.working())
        #expect(rig.hasArmedWake, "a working chip armed no minute")
        rig.fireAndRun()
        #expect(rig.elapsed >= 60, "the minute fired \(rig.elapsed) s in")
        #expect(node.deferredCount == 1, "the hidden sidebar's minute did not wait for it to show")
        #expect(!rig.hasArmedWake, "a hidden sidebar kept waking each minute")

        node.set(.visible)
        #expect(node.deferredCount == 0, "the minute did not redraw on show")
        #expect(rig.hasArmedWake, "the shown panel armed no next minute")
    }

    @Test func aShownSidebarsMinuteRedrawsInItsWakeAndStopsWithTheLastWorkingChip() {
        let rig = MainDeadlineRig()
        let node = VisibilityNode(root: "sidebar.list", own: .visible)
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.follow(rig.deadlines, visibility: node)
        view.show(Self.working())

        rig.fireAndRun()
        #expect(node.deferredCount == 0, "a shown sidebar's minute waited")
        #expect(rig.hasArmedWake, "the minute armed no next one")

        view.show(SidebarPriorityPanel(entries: []))
        #expect(!rig.hasArmedWake, "the minute stayed armed with no working chip")
    }

    // MARK: Service: the container's presentation and width observation (R-obs)

    @Test func aWidthChangeAppliesAsOnePostedTaskWithNoWindow() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let model = SidebarModel()
        let container = SidebarContainerView(model: model, deadlines: rig.deadlines, appEvents: AppEvents(center: NotificationCenter()))
        rig.frame()
        let before = container.panelWidth.constant
        let posted = rig.work.postedCount(.visible)

        model.width = before + 20
        #expect(container.panelWidth.constant == before, "the width applied in the change's own turn")
        #expect(rig.work.postedCount(.visible) > posted, "the width's flush is not a posted visible task")
        rig.frame()
        #expect(container.panelWidth.constant == model.width, "the posted flush did not apply the width")
        #expect(container.window == nil)
    }

    /// Rule 2: the person's own width change (a drag of the handle, a toggle) applies in the input-response pass, before
    /// the commit of their input, not in the posted visible task a program change waits for.
    @Test func aPersonsWidthChangeAppliesInTheInputResponsePassBeforeAnyFrame() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let model = SidebarModel()
        let container = SidebarContainerView(model: model, deadlines: rig.deadlines, appEvents: AppEvents(center: NotificationCenter()))
        rig.frame()
        let before = container.panelWidth.constant

        rig.work.causes.withCause(.person) { model.width = before + 20 }
        #expect(container.panelWidth.constant == before, "the width applied inside the change's will-set")
        #expect(rig.work.causes.flushPersonCaused() >= 1, "the person's width change did not reach the input-response pass")
        #expect(container.panelWidth.constant == model.width, "the person's width waited for a frame or a posted task")
        #expect(model.width == before + 20)
    }

    // MARK: Person input state: the list's gesture ends on focus loss (R-notif)

    /// A list in a window whose notices post on `windowCenter` (the window's WindowEvents is made on it first).
    private static func list(events: AppEvents, windowCenter: NotificationCenter = NotificationCenter()) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("x")), .workspace(ws("y"))])],
                                 activeWorkspaceID: WorkspaceID("x"))
        let list = SidebarListView(model: model)
        list.appEvents = events // before the window: the list subscribes when it moves into one
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        _ = WindowEvents.of(window, center: windowCenter)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    @Test func theAppResigningActiveEndsAHeldDragThroughTheInjectedAppEvents() throws {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let (list, window) = Self.list(events: events)
        defer { window.close() }
        #expect(events.subscriberCount(NSApplication.didResignActiveNotification) == 1)
        let start = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("x")))
        try SidebarPointerGestureTests.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 30)], release: false)
        #expect(list.drag != nil)

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(list.drag == nil, "the drag outlived the app's focus")
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    @Test func theWindowResigningKeyWithTheButtonUpEndsAHeldPress() throws {
        let center = NotificationCenter()
        let (list, window) = Self.list(events: AppEvents(center: NotificationCenter()), windowCenter: center)
        defer { window.close() }
        let events = WindowEvents.of(window)
        #expect(events.subscriberCount(NSWindow.didResignKeyNotification) >= 1)
        list.leftButtonIsDown = { false }
        let start = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("y")))
        try SidebarPointerGestureTests.press(list, at: start, moves: [], release: false)
        #expect(list.holdsPointerGesture)

        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!list.holdsPointerGesture, "the press outlived its window's key with the button up")
    }

    // MARK: Person: the spring-load hover of an external tab drag (R-timer)

    @Test func theSpringLoadIsAUserBlockingDeadlineThatLeavingTheRowCancels() throws {
        let rig = MainDeadlineRig()
        let (list, window) = Self.list(events: AppEvents(center: NotificationCenter()))
        defer { window.close() }
        list.deadlines = rig.deadlines
        let spring = try #require(list.springLoad, "the injected deadlines made no spring-load deadline")
        #expect(spring.workClass == .userBlocking, "the hover a person waits on is not the rest of their action")
        let y = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("y")))
        let hit = list.externalDragMoved(windowPoint: list.convert(y, to: nil), sourceMachine: nil)
        try #require(hit?.0 == .intoWorkspace(WorkspaceID("y")), "no workspace drop on y: \(String(describing: hit))")
        #expect(spring.isScheduled && rig.hasArmedWake, "holding the tab on a row armed no spring-load")

        list.externalDragExited()
        #expect(!spring.isScheduled, "the spring-load stayed armed after the tab left the row")
        rig.fireAndRun()
        #expect(!list.model.selection.contains(WorkspaceID("y")), "a cancelled spring-load selected the row")
    }

    @Test func theSpringLoadSelectsTheHeldRowAtItsDeadlineAndNotBefore() throws {
        let rig = MainDeadlineRig()
        let (list, window) = Self.list(events: AppEvents(center: NotificationCenter()))
        defer { window.close() }
        list.deadlines = rig.deadlines
        let y = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("y")))
        let hit = list.externalDragMoved(windowPoint: list.convert(y, to: nil), sourceMachine: nil)
        try #require(hit?.0 == .intoWorkspace(WorkspaceID("y")), "no workspace drop on y: \(String(describing: hit))")

        rig.advance(by: .milliseconds(100))
        rig.fireAtNow()
        #expect(!list.model.selection.contains(WorkspaceID("y")), "the spring-load selected the row before its delay")
        rig.fireAndRun()
        #expect(rig.elapsed >= 0.5, "the spring-load fired \(rig.elapsed) s in")
        #expect(list.model.selection.contains(WorkspaceID("y")), "the held row was not selected at its deadline")
        #expect(list.springLoad?.isScheduled == false)
        _ = list.externalDragEnded()
    }

    // MARK: The key-window repaint (R-notif)

    @Test func keyWindowRepaintsShareOneObserverPerWindowAndNotice() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let center = NotificationCenter()
        let events = WindowEvents.of(window, center: center) // made first: the repaints' WindowEvents.of(window) returns it
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = root
        let views = [NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)), NSView(frame: NSRect(x: 20, y: 0, width: 20, height: 20))]
        let repaints = views.map { view in
            root.addSubview(view)
            return KeyWindowRepaint(view)
        }
        for repaint in repaints { repaint.track() }
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 2)
        #expect(events.subscriberCount(NSWindow.didResignKeyNotification) == 2)
        let delivered = events.deliveries(NSWindow.didResignKeyNotification)
        for view in views { view.needsDisplay = false }

        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(events.deliveries(NSWindow.didResignKeyNotification) == delivered + 1, "one post reached the window more than once")
        #expect(views.allSatisfy { $0.needsDisplay }, "a view did not repaint for its window's key change")
        withExtendedLifetime(repaints) {}
    }
}
