import AppKit
@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextApp/{Cloud,SessionTransfer,ServerUpdates} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// task p06-scheduler-312): one case per migrated owner class. The New Cloud Workspace progress view reads nothing
/// while its window is hidden and catches up once when it shows, and its elapsed ticker wakes only while it shows;
/// a create's backoff is a classed `MainDeadline` on the app's one scheduler (here a rig whose wakes the test fires).
@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudSchedulerSweepTests {
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "no capacity" }
    }

    private static func progressView(_ creation: CloudMachineCreation, parent: VisibilityNode,
                                      rig: MainDeadlineRig) -> (CloudMachineProgressView, NSWindow) {
        _ = NSApplication.shared
        let view = CloudMachineProgressView(creation: creation, actions: .init(retry: { _ in }, dismiss: { _ in }),
                                            parent: parent, mainWork: rig.deadlines.work, deadlines: rig.deadlines)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, window)
    }

    // MARK: VisibleObservation on the window's node (CloudMachineProgressView)

    @Test func aHiddenWindowsProgressViewRendersAFailureOnlyWhenItShows() {
        let rig = MainDeadlineRig(), parent = VisibilityNode(root: "window", own: .hidden)
        let creation = CloudMachineCreation(windowID: nil)
        let (view, window) = Self.progressView(creation, parent: parent, rig: rig)
        defer { window.close() }
        let before = view.detailText
        #expect(!view.showsButtons)

        creation.fail(Refused())
        rig.frame()
        #expect(view.detailText == before, "a hidden window's progress view rendered the failure")
        #expect(!view.showsButtons)

        parent.set(.visible)
        #expect(view.detailText != before, "the progress view did not render the failure in the show turn")
        #expect(view.showsButtons, "the shown failure offers no Retry")
    }

    // MARK: MainDeadline (the elapsed ticker)

    @Test func theElapsedTickerWakesOnlyWhileTheViewShows() {
        let rig = MainDeadlineRig(), parent = VisibilityNode(root: "window", own: .visible)
        let creation = CloudMachineCreation(windowID: nil)
        let (_, window) = Self.progressView(creation, parent: parent, rig: rig)
        defer { window.close() }
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(1) && $0 <= .seconds(2) } == true,
                "a shown, running creation planned no elapsed tick one second away")

        parent.set(.hidden)
        #expect(rig.deadlines.nextFire == nil, "a hidden progress view kept its elapsed wake")

        parent.set(.visible)
        #expect(rig.deadlines.nextFire != nil, "the shown view did not tick again")
        creation.fail(Refused())
        rig.frame()
        #expect(rig.deadlines.nextFire == nil, "a finished creation kept ticking")
    }

    // MARK: MainPause (the create flow's approval backoff)

    @Test func aPauseResumesWhenItsDeadlineFiresNotBefore() async throws {
        let rig = MainDeadlineRig()
        let pause = MainPause(owner: "test.pause", workClass: .visible, scheduler: rig.deadlines)
        let waiter = Task { try await pause.delay(.seconds(2)) }
        while !pause.isWaiting { await Task.yield() }
        #expect(rig.hasArmedWake, "the pause armed no wake on the main thread's queue")
        rig.frame()
        #expect(pause.isWaiting, "a frame with no wake ended the pause")

        rig.fireAndRun()
        try await waiter.value
        #expect(rig.elapsed >= 2, "the pause ended \(rig.elapsed) s in, before its 2 s")
        #expect(!rig.hasArmedWake)
    }
}
