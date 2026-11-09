import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
import CmuxNextDaemonService
import CmuxNextSidebar
import Foundation
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

    private static func standInScript(root: URL, session: String) -> String {
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
            for waited in 0 1000 2000; do
                printf '{"progress":"restoring","session":"\(session)","pid":4242,"waited_ms":%s}\\n' "$waited"
                sleep 1
            done
            echo '{"status":"started","session":"\(session)","socket":"\(root.path)/gone.sock","pid":4242,"generation":"g-1","message":"started"}'
            exit 0 ;;
        esac
        exit 64
        """
    }

    private static func launch() throws -> Launched {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-restore-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = "cn-restore-\(UUID().uuidString.prefix(8).lowercased())"
        let binary = root.appendingPathComponent("cmux-tui")
        try standInScript(root: root, session: session).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        // As the app's launcher: bundled, so the ensure passes `--restore-progress`.
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"),
                                 binaryIsBundled: true, webSocketPageOrigins: ["http://127.0.0.1:1"]),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })
        _ = NSApplication.shared
        let environment = AppEnvironment.current([:])
        let services = AppServices(environment: environment)
        services.windows.ordersWindowsIn = false
        services.daemon.recovery.restartsUnresponsiveOwner = { false }
        let prestart = DaemonPrestart(launcher: launcher, configuration: DaemonConnection.Configuration(terminalEnvironment: nil))
        services.daemon.start(launch: environment.launch, terminalEnvironment: [:], terminalEnvironmentProvider: { [:] },
                              prestart: prestart)
        services.windows.restoreWhenLoaded()
        return Launched(services: services, root: root)
    }

    @Test func theRestoreShowsWhileTheEnsureWaitsAndGoesWhenItAnswers() async throws {
        let started = ContinuousClock.now
        let launched = try Self.launch()
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
}
