import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The CmuxNextApp/Windows sweep (plans/cmux-next/chrome-parity/p06-scheduler.md): one case
/// per migrated owner class. A window's view observation reads nothing while the window is hidden and applies once
/// when it shows; a wait ends on its condition or its deadline, never by a poll; the window's deadlines run as
/// classed `MainDeadline`s on the app's one scheduler (here a rig whose wakes the test fires).
@MainActor @Suite(.timeLimit(.minutes(1))) struct WindowsSchedulerSweepTests {
    // MARK: VisibleObservation on the window's node (TitlebarToolbarBand)

    @Test func aHiddenWindowsToolbarBandReadsNoRebindUntilItShows() {
        let rig = MainDeadlineRig(), names = ToggleNames(), node = VisibilityNode(root: "window", own: .visible)
        let band = TitlebarToolbarBand(frame: .zero)
        band.follow(on: node, work: rig.deadlines.work, title: { names.read() }, shortcut: { nil })
        #expect(band.sidebarToggle.accessibilityLabel() == "Hide Sidebar", "the first value applies in the caller's turn")
        #expect(names.reads == 1)

        node.set(.hidden)
        for index in 1...20 { names.title = "Toggle \(index)" }
        rig.frame()
        #expect(names.reads == 1, "a hidden window's band read the title \(names.reads - 1) times")
        #expect(band.sidebarToggle.accessibilityLabel() == "Hide Sidebar")

        node.set(.visible)
        #expect(names.reads == 2, "the show reads once, in the show turn")
        #expect(band.sidebarToggle.accessibilityLabel() == "Toggle 20")
    }

    @Test func aShownWindowsToolbarBandAppliesABurstOnce() {
        let rig = MainDeadlineRig(), names = ToggleNames(), node = VisibilityNode(root: "window", own: .visible)
        let band = TitlebarToolbarBand(frame: .zero)
        band.follow(on: node, work: rig.deadlines.work, title: { names.read() }, shortcut: { nil })
        names.title = "A"
        names.title = "B"
        #expect(band.sidebarToggle.accessibilityLabel() == "Hide Sidebar", "a change applies nothing in its own turn")
        // Each change re-arms the tracking with one read (VisibleObservation rule 2); the frame reads and applies once.
        let beforeFrame = names.reads
        rig.frame()
        #expect(band.sidebarToggle.accessibilityLabel() == "B")
        #expect(names.reads == beforeFrame + 1, "two changes in one turn applied \(names.reads - beforeFrame) times on the frame")
        rig.frame()
        #expect(names.reads == beforeFrame + 1, "a frame with no change read the title again")
    }

    // MARK: ServiceObservation (WindowController.sidebarHidden)

    @Test func aHiddenWindowsSidebarToggleStillAppliesOnTheFrame() throws {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"sweep-hidden","workspace_key":"k1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services,
                                          frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        controller.visibility.set(.hidden)
        try #require(!controller.visibility.isVisible)
        try #require(!controller.root.sidebarHidden, "the first value applies when the observation starts")

        controller.sidebar.model.presentation = .hidden
        rig.frame()
        // The hover cards and the pages hear it from here, so it must not wait for the window to show.
        #expect(controller.root.sidebarHidden, "a hidden window's sidebar observation waited for the window to show")
        withExtendedLifetime(services) {}
    }

    // MARK: ObservedCondition (FirstTabHold, DaemonStore.mirrored)

    @Test func aConditionThatHoldsNowEndsTheWaitWithNoDeadline() async {
        let rig = MainDeadlineRig()
        await ObservedCondition(owner: "test.now", .visible, on: rig.deadlines.work)
            .until(timeout: .seconds(2), deadlines: rig.deadlines) { true }
        #expect(!rig.hasArmedWake, "a satisfied wait armed its timeout")
    }

    @Test func aWaitEndsOnTheFrameAfterItsConditionHolds() async {
        let rig = MainDeadlineRig(), flag = Flag()
        let condition = ObservedCondition(owner: "test.flip", .visible, on: rig.deadlines.work)
        let waiter = Task { await condition.until(timeout: .seconds(2), deadlines: rig.deadlines) { flag.isOn } }
        while !condition.isWaiting { await Task.yield() }
        #expect(rig.hasArmedWake)
        flag.isOn = true
        rig.frame()
        await waiter.value
        #expect(!condition.isWaiting)
        #expect(!rig.hasArmedWake, "the timeout stayed armed after the condition held")
    }

    @Test func aWaitWhoseConditionNeverHoldsEndsAtItsDeadline() async {
        let rig = MainDeadlineRig(), flag = Flag()
        let condition = ObservedCondition(owner: "test.timeout", .visible, on: rig.deadlines.work)
        let waiter = Task { await condition.until(timeout: .seconds(2), deadlines: rig.deadlines) { flag.isOn } }
        while !condition.isWaiting { await Task.yield() }
        rig.fireAndRun()
        await waiter.value
        #expect(rig.elapsed >= 2, "the wait ended \(rig.elapsed) s in, before its 2 s bound")
        flag.isOn = true
        rig.frame()
        #expect(!condition.isWaiting)
    }

    // MARK: MainDeadline (CollapsedBandReveal, RestoredFullScreen)

    @Test func theCollapsedBandClosesOnItsDeadlineAndAReturnKeepsItOpen() {
        let rig = MainDeadlineRig()
        let band = CollapsedBandReveal(deadlines: rig.deadlines, fullWidth: { TitlebarToolbarBand.width }, rendersOnServer: { true })
        band.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        band.setSidebarHidden(true)
        band.setEngaged(true)
        #expect(band.isOpen)
        band.setEngaged(false)
        #expect(band.isOpen, "the band closes after its delay, not at once")
        band.setEngaged(true)
        rig.fireAndRun()
        #expect(band.isOpen, "a return before the delay cancelled the close")
        band.setEngaged(false)
        rig.fireAndRun()
        #expect(!band.isOpen)
        #expect(rig.elapsed >= 0.3)
    }

    @Test func aRestoredFullScreenSettlesAfterItsTransitionBegins() {
        let rig = MainDeadlineRig(), window = Self.window()
        defer { window.close() }
        var done = 0
        let center = NotificationCenter(), events = WindowEvents(window: window, center: center)
        let restore = RestoredFullScreen(window: window, events: events, deadlines: rig.deadlines) { done += 1 }
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(done == 0, "the next window waited no settle time")
        rig.fireAndRun()
        #expect(done == 1)
        #expect(rig.elapsed < 1, "it waited for the 3 s start bound after the transition began")
        withExtendedLifetime((restore, events)) {}
    }

    @Test func aRestoredFullScreenWhoseTransitionNeverBeginsGoesOnAfterItsBound() {
        let rig = MainDeadlineRig(), window = Self.window()
        defer { window.close() }
        var done = 0
        let center = NotificationCenter(), events = WindowEvents(window: window, center: center)
        let restore = RestoredFullScreen(window: window, events: events, deadlines: rig.deadlines) { done += 1 }
        rig.fireAndRun()
        #expect(done == 0, "the start bound passed: the settle time follows")
        rig.fireAndRun()
        #expect(done == 1)
        #expect(rig.elapsed >= 3.8)
        withExtendedLifetime((restore, events)) {}
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor @Observable
private final class ToggleNames {
    var title = "Hide Sidebar"
    @ObservationIgnored private(set) var reads = 0

    func read() -> String {
        reads += 1
        return title
    }
}

@MainActor @Observable
private final class Flag {
    var isOn = false
}
