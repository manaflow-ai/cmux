import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextDesign
import Foundation
import Testing

/// An owner that stays alive but never answers restarts without anyone pressing Restart cmux-tui
/// (`UnresponsiveOwnerWatch` in `DaemonRecovery`): after plain `server ensure` runs kept failing
/// the way a stuck owner makes them fail for the sustained window, the app runs the same
/// `server ensure --replace-unresponsive` the button runs after its confirm, with no confirm.
/// The terminal hosts outlive the replaced owner (durable-sessions.md), so nothing is lost.
///
/// As `DaemonRestartTests`: the app's real startup path on a stand-in `cmux-tui` script (never a
/// real daemon, never a signal). Its plain ensure fails with `server.restore_timeout` while the
/// `stuck` marker exists; its replace answers `replaced` and clears the marker (the new owner
/// starts), after which a plain ensure fails another way.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DaemonAutoRestartTests {
    private struct StandIn {
        let root: URL
        var log: URL { root.appendingPathComponent("calls.log") }
        var stuck: URL { root.appendingPathComponent("stuck") }

        func ensures() -> [[String]] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n")
                .map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
                .filter { $0.contains("ensure") }
        }

        func replaces() -> Int { ensures().count { $0.contains("--replace-unresponsive") } }
    }

    private static func script(_ standIn: StandIn, session: String) -> String {
        """
        #!/bin/sh
        line=""
        for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
        printf '%s\\n' "${line#?}" >> '\(standIn.log.path)'
        case " $* " in
        *" --version "*) echo 'cmux-tui 0.1.0'; exit 0 ;;
        *" server status "*) exit 1 ;;
        *" --replace-unresponsive "*)
            rm -f '\(standIn.stuck.path)'
            echo '{"status":"replaced","session":"\(session)","socket":"\(standIn.root.path)/gone.sock","pid":4242,"generation":"g-2","replaced_pid":4141,"message":"replaced"}'
            exit 0 ;;
        *" server ensure "*)
            if [ -e '\(standIn.stuck.path)' ]; then
                echo '{"code":"server.restore_timeout","message":"the session owner is still restoring","details":{},"retryable":false}' >&2
            else
                echo '{"code":"server.spawn_failed","message":"could not start the session owner","details":{},"retryable":false}' >&2
            fi
            exit 3 ;;
        esac
        exit 64
        """
    }

    /// The app's startup path on a stuck stand-in, with a 1 s window instead of 30 s.
    private static func launch(automatic: Bool) throws -> (services: AppServices, standIn: StandIn) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-autorestart-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let standIn = StandIn(root: root)
        FileManager.default.createFile(atPath: standIn.stuck.path, contents: Data())
        let session = "cn-autorestart-\(UUID().uuidString.prefix(8).lowercased())"
        let binary = root.appendingPathComponent("cmux-tui")
        try script(standIn, session: session).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"),
                                 binaryIsBundled: true, webSocketPageOrigins: ["http://127.0.0.1:1"]),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })
        _ = NSApplication.shared
        let environment = AppEnvironment.current([:])
        let services = AppServices(environment: environment)
        services.windows.ordersWindowsIn = false
        let recovery = services.daemon.recovery
        recovery.unresponsivePolicy = UnresponsiveOwnerWatch.Policy(sustained: .seconds(1), stuckEnsures: 2, perLaunch: 3)
        if !automatic { recovery.restartsUnresponsiveOwner = { false } }
        let prestart = DaemonPrestart(launcher: launcher, configuration: DaemonConnection.Configuration(terminalEnvironment: nil))
        services.daemon.start(launch: environment.launch, terminalEnvironment: [:], terminalEnvironmentProvider: { [:] },
                              prestart: prestart)
        return (services, standIn)
    }

    private static func stop(_ services: AppServices, _ standIn: StandIn) {
        CmuxDialogCenter.shared.dismissAll()
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }
        try? FileManager.default.removeItem(at: standIn.root)
    }

    /// Polls until `done` holds or `limit` passes (as `DaemonRestartTests` does).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aStuckOwnerIsReplacedWithNoConfirmAfterTheWindow() async throws {
        let (services, standIn) = try Self.launch(automatic: true)
        defer { Self.stop(services, standIn) }
        await Self.wait(within: .seconds(40)) { standIn.replaces() > 0 }
        let ensures = standIn.ensures()
        let replace = try #require(ensures.firstIndex { $0.contains("--replace-unresponsive") }, "the stuck owner was never replaced")
        // Only after two stuck ensures, and the same ensure the app runs, plus the option.
        #expect(replace >= 2)
        let plain = try #require(ensures[..<replace].last)
        #expect(ensures[replace] == plain + ["--replace-unresponsive"])
        #expect(!CmuxDialogCenter.shared.records.contains { $0.spec.identifier == "cmux.dialog.restartDaemon" },
                "the automatic restart asked the confirm")

        // Then the app connects again (a plain ensure), and the owner is not replaced again.
        await Self.wait(within: .seconds(10)) { standIn.ensures().count > replace + 1 }
        #expect(standIn.ensures()[(replace + 1)...].contains { !$0.contains("--replace-unresponsive") })
        try? await Task.sleep(for: .seconds(2))  // past another window: a second replace would show
        #expect(standIn.replaces() == 1)
    }

    @Test func theToggleOffLeavesTheRestartToThePerson() async throws {
        let (services, standIn) = try Self.launch(automatic: false)
        defer { Self.stop(services, standIn) }
        // Stuck ensures well past the window.
        let start = ContinuousClock.now
        await Self.wait(within: .seconds(40)) { standIn.ensures().count >= 4 && ContinuousClock.now - start > .seconds(3) }
        #expect(standIn.ensures().count >= 2)
        #expect(standIn.replaces() == 0, "the owner was replaced with the toggle off")
        #expect(services.daemon.recovery.offersRestart)
    }
}
