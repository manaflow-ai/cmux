import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextSignposts
@testable import CmuxNextTrace
import QuartzCore
import Testing

/// `switch.workspace`'s input age: the begin's `arg0` is the age in µs of the input the switch
/// answers, the same input its action run's `action.*` row reads: the key or click being dispatched, a page's click
/// carried with its request, or the press of the person's action run in progress. A switch nothing a person did in
/// this app asked for (a socket or CLI `workspace` select) has none (all ones), however recent the last click was.
@MainActor @Suite(.serialized)
struct WorkspaceSwitchInputAgeTests {
    private struct Harness {
        let services: AppServices
        let a: WindowController
        let log: WorkspaceSwitchRecordLog

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
        }

        /// Shows `ws-b2` (window B lists it) in window A, as a pick in window A's sidebar does.
        func pick() {
            services.windows.show(workspaceID: "ws-b2", in: a.state, from: .thisWindow)
        }

        /// The input age of each switch begun, in µs (`UInt64.max`: no input).
        var ages: [UInt64] { log.records.filter { $0.phase == .asyncBegin }.map(\.arg0) }
    }

    /// Window A shows `ws-a1`, window B lists `ws-b1` and `ws-b2`; every window times into one timer on its own runtime.
    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let a = try #require(services.windows.openWindow(workspaces: ["ws-a1"]))
        _ = try #require(services.windows.openWindow(workspaces: ["ws-b1", "ws-b2"]))
        let log = WorkspaceSwitchRecordLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.switch.traceBit))
        let timer = SwitchFrameTimer(owner: "test.workspace_switch", signpost: .switchWorkspace, trace: runtime)
        for controller in services.windows.controllers { controller.workspaceSwitchTimer = timer }
        return Harness(services: services, a: a, log: log)
    }

    private static func click(agedSeconds age: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: CACurrentMediaTime() - age,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// A sidebar click is being dispatched when its switch begins: the click's age is the input stage.
    @Test func theClickBeingDispatchedIsTheSwitchInput() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let click = try Self.click(agedSeconds: 0.003)
        harness.services.inputDispatch.dispatching(click) { harness.pick() }
        let ages = harness.ages
        try #require(ages.count == 1)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the click 3 ms old: \(ages[0]) µs (all ones: no input stage)")
    }

    /// A socket or CLI switch a moment after a click: `NSApp.currentEvent` still holds the click, but nothing is being
    /// dispatched and no person's run is in progress, so the switch has no input age.
    @Test func aRecentClickLeftInCurrentEventIsNoSwitchInput() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let stale = try Self.click(agedSeconds: 0.003)
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil, "NSApplication has no _currentEvent ivar on this macOS")
        NSApp.setValue(stale, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }
        try #require(NSApp.currentEvent?.type == .leftMouseDown, "the test could not leave a recent click in currentEvent")
        harness.pick()
        #expect(harness.ages == [.max], "a socket switch took the last click's age: \(harness.ages)")
    }

    /// A person's run that switches after its press's dispatch ended (a run a confirmation let through, a run's task
    /// after a daemon reply) answers that press, as its `action.*` row does.
    @Test func aPersonsRunSwitchingAfterItsDispatchAnswersItsPress() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let run = ActionRunScope(origin: .user, allowsViewChange: true, inputTimestamp: CACurrentMediaTime() - 0.003)
        ActionRunScope.$current.withValue(run) { harness.pick() }
        let ages = harness.ages
        try #require(ages.count == 1)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the run's press 3 ms old: \(ages[0]) µs")
    }

    /// The New Tab page's location bar picks a workspace: the page's click comes back with its `tab.jump` a turn after
    /// its own dispatch, and the switch takes that click's age.
    @Test func aNewTabPageJumpAnswersThePagesClick() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let shell = try #require(harness.a.window)
        harness.services.keyWindowSource = { shell }
        NewTabPage.jump(.workspace, id: "ws-b2", inputTimestamp: CACurrentMediaTime() - 0.003, services: harness.services)
        let ages = harness.ages
        try #require(ages.count == 1)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the page's click 3 ms old: \(ages[0]) µs")
    }
}

private nonisolated final class WorkspaceSwitchRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) {
        state.withLock { $0.append(record) }
    }

    /// The `switch.workspace` records written so far.
    var records: [TraceRuntime.StubRecord] {
        state.withLock { $0 }.filter { $0.name == SignpostName.switchWorkspace.rawValue }
    }
}
