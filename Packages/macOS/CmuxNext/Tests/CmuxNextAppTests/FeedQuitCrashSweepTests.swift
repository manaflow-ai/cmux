import AppKit
@testable import CmuxNextApp
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The CmuxNextApp/{Feed,HangReports,Crash,ErrorJournal,Quit,Usage,SidebarSnapshot} sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-314): one case per migrated owner class.
/// The quit's power-off notice reaches its tracker through the app's one `AppEvents` fan-out (an always
/// subscription: it must land while no window shows); the restart notice follows its window through
/// `WindowEvents`; the run marker's quick-crash window is a background `MainDeadline` on the app's scheduler.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FeedQuitCrashSweepTests {
    // MARK: AppEvents (QuitOriginTracker)

    @Test func aPowerOffNoticeMakesTheNextQuitAPowerOffThroughTheAppsOneObserver() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let tracker = QuitOriginTracker(workspaceEvents: events)
        #expect(events.isObserving(NSWorkspace.willPowerOffNotification), "the tracker made no subscription")
        tracker.record(.interactive)
        #expect(tracker.consume() == .interactive)

        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        #expect(tracker.isPoweringOff, "the power-off notice did not reach the tracker")
        #expect(events.deliveries(NSWorkspace.willPowerOffNotification) == 1)
        tracker.record(.interactive)
        #expect(tracker.consume() == .powerOff, "a quit after the power-off notice asked like an interactive one")
    }

    // MARK: WindowEvents (RestartNoticePanel)

    @Test func theRestartNoticeFollowsItsWindowAndClosesWithIt() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The window's events on the test's own center: the test posts what AppKit would.
        let center = NotificationCenter()
        let notice = RestartNoticePanel(text: "cmux restarted after a problem", onShowLog: nil)
        notice.show(on: window, center: center)
        let events = WindowEvents.of(window)
        #expect(events.subscriberCount(NSWindow.didResizeNotification) == 1)
        #expect(events.subscriberCount(NSWindow.didMoveNotification) == 1)
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 1)
        #expect(notice.isShown)

        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 600), display: false)
        center.post(name: NSWindow.didResizeNotification, object: window)
        #expect(events.deliveries(NSWindow.didResizeNotification) == 1)
        let panel = try #require(window.childWindows?.first, "the notice is not the window's child")
        #expect(abs(panel.frame.midX - window.frame.midX) < 1, "the notice did not follow the window's resize")
        #expect(abs(panel.frame.minY - (window.frame.minY + 16)) < 1)

        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!notice.isShown, "the notice stayed after its window closed")
    }

    // MARK: MainDeadline (AppRunMarker's quick-crash window)

    /// A run marker installs the app's fatal-signal handlers, so each case runs it in a child process (an exit test)
    /// and reads the folder it left, the way the next launch does.
    @Test func aRunPastTheQuickCrashWindowIsMarkedSurvived() async throws {
        let directory = CrashChild.directory("survival-past", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await CrashChild.armTheQuickCrashWindow(name: "survival-past", livedSeconds: 61)
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.survived, "the window's background deadline did not mark the run survived")
    }

    @Test func aRunInsideTheQuickCrashWindowIsNotMarkedSurvived() async throws {
        let directory = CrashChild.directory("survival-inside", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await CrashChild.armTheQuickCrashWindow(name: "survival-inside", livedSeconds: 10)
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(!previous.survived, "a run 10 s old was marked past the 60 s window")
    }
}

extension CrashChild {
    /// The launch's run marker with its quick-crash window armed `livedSeconds` after the launch, on a deadline rig
    /// the child fires by hand: a window that is over fires at once, one that is not stays armed. Exits 0 once
    /// `run.json` holds the outcome, 1 when the deadline was not where it belongs.
    @MainActor
    static func armTheQuickCrashWindow(name: String, livedSeconds: TimeInterval) async {
        let marker = await markRun(name)
        let rig = MainDeadlineRig()
        marker.armSurvivalWindow(on: rig.deadlines, now: Date().addingTimeInterval(livedSeconds))
        guard rig.hasArmedWake else { exit(1) }
        if livedSeconds >= 60 {
            rig.fireAndRun()
        } else {
            rig.frame()
        }
        _ = await marker.flush()
        withExtendedLifetime(marker) {}
        exit(0)
    }
}
