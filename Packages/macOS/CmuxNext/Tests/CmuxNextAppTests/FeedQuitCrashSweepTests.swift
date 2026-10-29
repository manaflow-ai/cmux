import AppKit
@testable import CmuxNextApp
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The CmuxNextApp/{Feed,HangReports,Crash,ErrorJournal,Quit,Usage,SidebarSnapshot} sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md): one case per migrated owner class.
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
    @Test func aRunPastTheQuickCrashWindowIsMarkedSurvivedAtOnce() async throws {
        let directory = CrashChild.directory("survival-past", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await CrashChild.armTheQuickCrashWindowPastItsEnd(name: "survival-past")
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.survived, "the window's background deadline did not mark the run survived")
    }

    @Test func aRunInsideTheQuickCrashWindowIsMarkedSurvivedOnlyWhenTheWindowEnds() async throws {
        let directory = CrashChild.directory("survival-inside", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await CrashChild.armTheQuickCrashWindowInsideIt(name: "survival-inside")
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.survived, "the window's background deadline did not mark the run survived at its end")
    }
}

extension CrashChild {
    /// A run 61 s old arms the 60 s quick-crash window on a deadline rig the child fires by hand: the wake is due at
    /// once (uptime does not move), and `run.json` says survived. Exits 1 on any mismatch.
    @MainActor
    static func armTheQuickCrashWindowPastItsEnd(name: String) async {
        let marker = await markRun(name)
        let rig = MainDeadlineRig()
        marker.armSurvivalWindow(on: rig.deadlines, now: Date().addingTimeInterval(61))
        guard rig.hasArmedWake else { exit(1) }
        rig.fireAndRun()
        guard rig.elapsed < 0.1 else { exit(1) }
        guard await survivedOnDisk(marker, name: name) else { exit(1) }
        exit(0)
    }

    /// A run 10 s old arms the 60 s quick-crash window: 49 s later (59 s lived) the queue fires and the run stays
    /// unsurvived with the wake still armed; the armed wake is about 50 s after the arm (60 s lived), and its fire marks
    /// the run survived. Exits 1 on any mismatch.
    @MainActor
    static func armTheQuickCrashWindowInsideIt(name: String) async {
        let marker = await markRun(name)
        let rig = MainDeadlineRig()
        marker.armSurvivalWindow(on: rig.deadlines, now: Date().addingTimeInterval(10))
        guard rig.hasArmedWake else { exit(1) }
        rig.advance(by: .seconds(49))
        rig.fireAtNow()
        guard rig.hasArmedWake else { exit(1) }
        guard await !survivedOnDisk(marker, name: name) else { exit(1) }
        rig.fireAndRun()
        guard (49.9...51.1).contains(rig.elapsed) else { exit(1) }
        guard await survivedOnDisk(marker, name: name) else { exit(1) }
        exit(0)
    }

    /// Whether `run.json` says survived once the marker's writes are on disk.
    @MainActor
    private static func survivedOnDisk(_ marker: AppRunMarker, name: String) async -> Bool {
        _ = await marker.flush()
        return previous(in: directory(name, parent: getppid()))?.survived == true
    }
}
