import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
@testable import CmuxNextDaemonService
import Observation
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import os
import Testing

/// Leo, 2026-11-08: after a restart the session owner restored for 30 minutes, the window said only
/// "cmux's background service isn't connected", and clicks on chats did nothing. While `server ensure
/// --restore-progress` reports the restore, the app now publishes it (`DaemonRecovery.restoring`), the
/// launch window says "Restoring sessions… <time>" and the sidebar shows the same status card; both go
/// once the ensure answers.
///
/// The app runs its real startup path against a stand-in `cmux-tui` script (as DaemonRestartTests):
/// `server status` finds no owner, the first `server ensure` prints three progress lines a second
/// apart and then its reply, and later ensures fail at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DaemonRestoreProgressTests {
    private struct Launched {
        let services: AppServices
        let root: URL

        var view: DaemonConnectingView? { services.windows.controllers.first?.connectingView }

        func stop() {
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// `waits`: the `waited_ms` of each progress line, `gap` the real seconds between two.
    private static func standInScript(root: URL, session: String, waits: [UInt64], gap: String) -> String {
        let done = root.appendingPathComponent("ensured").path
        return """
        #!/bin/sh
        case " $* " in
        *" --version "*) echo 'cmux-tui 0.1.0'; exit 0 ;;
        *" server status "*) exit 1 ;;
        *" server ensure "*)
            if [ -e '\(done)' ]; then
                echo '{"code":"server.spawn_failed","message":"could not start the session owner","details":{},"retryable":false}' >&2
                exit 3
            fi
            : > '\(done)'
            for waited in \(waits.map(String.init).joined(separator: " ")); do
                printf '{"progress":"restoring","session":"\(session)","pid":4242,"waited_ms":%s}\\n' "$waited"
                sleep \(gap)
            done
            echo '{"status":"started","session":"\(session)","socket":"\(root.path)/gone.sock","pid":4242,"generation":"g-1","message":"started"}'
            exit 0 ;;
        esac
        exit 64
        """
    }

    /// An app made ready to start against the stand-in, not started yet.
    private struct Prepared {
        let launched: Launched
        let launcher: DaemonLauncher
        let environment: AppEnvironment
    }

    /// `snapshot`: the workspace names of a launch snapshot the state directory holds (none: no file).
    private static func prepare(waits: [UInt64] = [0, 1000, 2000], gap: String = "1", snapshot: [String] = [],
                                startupDeadline: Duration? = nil) throws -> Prepared {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-restore-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = "cn-restore-\(UUID().uuidString.prefix(8).lowercased())"
        let binary = root.appendingPathComponent("cmux-tui")
        try standInScript(root: root, session: session, waits: waits, gap: gap).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        // As the app's launcher: bundled, so the ensure passes `--restore-progress`.
        if !snapshot.isEmpty {
            // cmux-tui keeps it in `<state>/<session>-<registry id>/launch-snapshot.json` (`LaunchSnapshotLocation.find`).
            let registry = root.appendingPathComponent("state/\(session)-reg1", isDirectory: true)
            try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
            let workspaces = snapshot.enumerated().map { #"{"id":\#($0.offset + 1),"name":"\#($0.element)"}"# }.joined(separator: ",")
            let file = #"{"schema_version":1,"session":"\#(session)","tree":{"workspaces":[\#(workspaces)]}}"#
            try Data(file.utf8).write(to: registry.appendingPathComponent("launch-snapshot.json"))
        }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"),
                                 binaryIsBundled: true, webSocketPageOrigins: ["http://127.0.0.1:1"]),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })
        _ = NSApplication.shared
        let environment = AppEnvironment.current([:])
        let services = AppServices(environment: environment)
        services.windows.ordersWindowsIn = false
        services.daemon.recovery.restartsUnresponsiveOwner = { false }
        if let startupDeadline { services.daemon.startupDeadline = startupDeadline }
        return Prepared(launched: Launched(services: services, root: root), launcher: launcher, environment: environment)
    }

    /// The app's start: the launch snapshot read on the files lane (as `main` starts it), then, as
    /// `AppDelegate.finishLaunching`, the daemon's start with that snapshot and the launch window.
    private static func launch(waits: [UInt64] = [0, 1000, 2000], gap: String = "1", snapshot: [String] = [],
                               startupDeadline: Duration? = nil) async throws -> Launched {
        let prepared = try prepare(waits: waits, gap: gap, snapshot: snapshot, startupDeadline: startupDeadline)
        let services = prepared.launched.services
        let names = prepared.launcher.configuration
        let saved = try await services.work.run(.userBlocking, mayBlock: .files) { LaunchSnapshot.saved(session: names.session, stateDirectory: names.stateDirectory) }
        let prestart = DaemonPrestart(launcher: prepared.launcher, configuration: DaemonConnection.Configuration(terminalEnvironment: nil))
        services.daemon.start(launch: prepared.environment.launch, terminalEnvironment: [:], terminalEnvironmentProvider: { [:] },
                              prestart: prestart, launchSnapshot: saved)
        services.windows.restoreWhenLoaded()
        return prepared.launched
    }

    /// LAUNCH 800 (2026-11-10): `DaemonService.start` runs on the main actor before the first window. It read the
    /// launch snapshot file and decoded its JSON there: 51 ms at the person's 826 workspaces (3.3 MB) against a few
    /// ms at 60, all before the window (aws-m4pro-7, `sample` of a Release launch). So a start that is handed no
    /// snapshot must not go to the disk for one: with a snapshot file in the state directory, the store shows
    /// nothing; the snapshot shows only when one read off the main actor is handed in (`launch`, as `main` does;
    /// `theAppStaysUsableThroughAFiveMinuteRestore` expects its workspaces).
    @Test func theDaemonStartReadsNoLaunchSnapshotFileOnTheMainActor() async throws {
        let prepared = try Self.prepare(waits: [0], gap: "0", snapshot: ["alpha", "beta"])
        defer { prepared.launched.stop() }
        let daemon = prepared.launched.services.daemon
        let prestart = DaemonPrestart(launcher: prepared.launcher, configuration: DaemonConnection.Configuration(terminalEnvironment: nil))
        daemon.start(launch: prepared.environment.launch, terminalEnvironment: [:], terminalEnvironmentProvider: { [:] },
                     prestart: prestart)
        #expect(!daemon.store.isProvisional && daemon.store.workspaces.isEmpty,
                "DaemonService.start read and decoded the launch snapshot file on the main actor: \(daemon.store.workspaces.count) workspaces show")
    }

    /// The launch window waits for the launch snapshot, so its read is first on the files lane: `main` posts the
    /// pages' and the terminals' saved frames (megabytes, decoded) on the same slot right after `readAtLaunch`
    /// returns. A read that entered the lane only when its task first ran queued behind them (review of #40660).
    @Test func theLaunchSnapshotReadIsOnTheFilesLaneBeforeTheReadsPostedAfterIt() async throws {
        let prepared = try Self.prepare(waits: [0], gap: "0", snapshot: ["alpha", "beta"])
        defer { prepared.launched.stop() }
        let names = prepared.launcher.configuration
        let work = BackgroundWork(label: "test.launch-snapshot")
        let order = OSAllocatedUnfairLock<[String]>(initialState: [])
        let read = LaunchSnapshot.readAtLaunch(work: work) {
            order.withLock { $0.append("snapshot") }
            return (names.session, names.stateDirectory)
        }
        work.post(.userBlocking, mayBlock: .files) { order.withLock { $0.append("frames") } }  // as `main`'s next launch read
        let snapshot = await read.value
        #expect(order.withLock { $0 }.first == "snapshot", "the launch snapshot read waited behind a read posted after it")
        #expect(snapshot?.tree.workspaces.map(\.name) == ["alpha", "beta"], "the read gave another snapshot")
    }

    @Test func theRestoreShowsWhileTheEnsureWaitsAndGoesWhenItAnswers() async throws {
        let started = ContinuousClock.now
        let launched = try await Self.launch()
        defer { launched.stop() }
        let recovery = launched.services.daemon.recovery
        var waited: [UInt64] = []
        var shownAt: ContinuousClock.Instant?
        var clearedAt: ContinuousClock.Instant?
        // Samples the published report until it came and went; only the suite's time limit ends a run that never
        // gets there (as DaemonRestartTests' wait).
        while clearedAt == nil, !Task.isCancelled {
            if let report = recovery.restoring {
                if waited.last != report.waitedMs { waited.append(report.waitedMs) }
                let title = RefusalStrings.restoringSessions(waitedMs: report.waitedMs)
                if shownAt == nil, launched.view?.titleText == title { shownAt = .now }
            } else if !waited.isEmpty {
                clearedAt = .now
            }
            try? await Task.sleep(for: .milliseconds(50))  // test harness sampling of the app's own steps
        }
        let shown = try #require(shownAt, "the launch window never said the sessions are restoring")
        let cleared = try #require(clearedAt)
        #expect(waited.count >= 2, "progress lines did not reach the app as they came: \(waited)")
        #expect(waited == waited.sorted() && Set(waited).count == waited.count, "the time shown stepped back: \(waited)")
        #expect(recovery.restoring == nil)
        #expect(launched.view?.titleText != RefusalStrings.restoringSessions(waitedMs: waited.last ?? 0))
        let card = SidebarNoticeCard.restoring(RefusalStrings.restoringSessions(waitedMs: 65_000))
        #expect(card.title == RefusalStrings.restoringSessions(waitedMs: 65_000))
        #expect(card.dismissLabel == nil && card.actions.isEmpty, "the status card asks the person for something")
        func ms(_ instant: ContinuousClock.Instant) -> Int64 {
            let elapsed = instant - started
            return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        }
        print("SELF_HEAL_PROBE app restore_status_shown_after_ms=\(ms(shown)) connected_after_ms=\(ms(cleared))")
    }

    /// Stands in for "connected" in the usable-during-restore probe: the stand-in's socket never answers, so the
    /// ensure's answer is the moment a live daemon would connect.
    @Observable @MainActor final class Answered { var value = false }
    /// What the held open and its toasts did, read by the test.
    @MainActor private final class Seen { var ranAt: ContinuousClock.Instant?; var toasts: [String] = [] }

    /// Leo, 2026-11-09: "updates need to be able to autorepair instead of getting the user to do this or that". A
    /// 5-minute restore (reported in injected time: `waited_ms` steps of a minute, a second apart) leaves the app
    /// usable with no user step: the launch snapshot's workspaces show, provisional (their rows stale, so read-only),
    /// the whole time; the restoring status shows and its time grows to 5 minutes; the startup deadline (shortened to
    /// 5 s here, shorter than the 6 s the stand-in reports for) never turns the window into a failure while progress comes; and a chat clicked during the restore is
    /// held and runs once the sessions answer.
    @Test func theAppStaysUsableThroughAFiveMinuteRestore() async throws {
        let launched = try await Self.launch(waits: stride(from: 0, through: 300_000, by: 60_000).map { UInt64($0) }, gap: "1",
                                       snapshot: ["alpha", "beta"], startupDeadline: .seconds(5))
        defer { launched.stop() }
        let daemon = launched.services.daemon
        let recovery = daemon.recovery
        let answered = Answered()
        let seen = Seen()
        let pending = PendingSessionOpen(ready: { answered.value }, activeWindow: { nil }, openWindows: { [] },
                                         show: { seen.toasts.append($0) })
        var clickedAt: ContinuousClock.Instant?
        var waited: [UInt64] = []
        var snapshotRows = Int.max
        var sawUnavailable = false
        while !Task.isCancelled {
            if let report = recovery.restoring {
                if waited.last != report.waitedMs { waited.append(report.waitedMs) }
                snapshotRows = min(snapshotRows, daemon.store.isProvisional ? daemon.store.workspaces.count : 0)
                if daemon.startup.isUnavailable { sawUnavailable = true }
                if clickedAt == nil {
                    clickedAt = .now
                    let held = pending.holds { seen.ranAt = .now }
                    #expect(held, "a click during the restore was not held")
                }
            } else if !waited.isEmpty {
                answered.value = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))  // test harness sampling of the app's own steps
        }
        while seen.ranAt == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }  // the held open's hop
        #expect(snapshotRows == 2, "the launch snapshot's workspaces did not show, provisional, through the restore")
        #expect(waited.count >= 3 && waited == waited.sorted(), "the restoring time did not grow: \(waited)")
        let longest = try #require(waited.last)
        #expect(longest >= 290_000, "the reported restore was not 5 minutes: \(longest) ms")
        #expect(!sawUnavailable, "the startup deadline showed a failure while the restore reported progress")
        #expect(seen.toasts == [RefusalStrings.pendingOpenWaits], "the held click said something else: \(seen.toasts)")
        let clicked = try #require(clickedAt), ran = try #require(seen.ranAt)
        let elapsed = ran - clicked
        let ranAfterMs = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("SELF_HEAL_PROBE app usable_during_restore_ms=\(longest) snapshot_workspaces=\(snapshotRows) pending_open_ran_after_ms=\(ranAfterMs)")
    }
}
