import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// cx-jniyz.1: a cmux-tui owner that accepts connections but never answers leaves the launch
/// window on "cmux-tui is unavailable" with nothing to press. The window offers Retry Now, and,
/// once a plain `server ensure` failed the way a stuck owner makes it fail (the daemon's restore
/// bound passed, or no answer), Restart cmux-tui: after a confirm it runs the same `server ensure`
/// with `--replace-unresponsive`, then tries to connect again. A refusal says so and leaves Retry.
///
/// The app runs its real startup path against a stand-in `cmux-tui` script (never a real daemon,
/// never a signal): `server status` finds no owner, `server ensure` fails as the test says, and
/// `server ensure --replace-unresponsive` answers `replaced` or a refusal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DaemonRestartTests {
    /// The stand-in's state: its call log and the files that pick its answers.
    private struct StandIn {
        let root: URL
        var log: URL { root.appendingPathComponent("calls.log") }
        /// Present: a plain ensure fails with `server.restore_timeout` (else `server.spawn_failed`).
        var stuck: URL { root.appendingPathComponent("stuck") }
        /// Present: `--replace-unresponsive` is refused (`server.replace_still_running`).
        var refuse: URL { root.appendingPathComponent("refuse") }

        /// Each call's arguments, in call order.
        func calls() -> [[String]] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
        }

        func ensures() -> [[String]] { calls().filter { $0.contains("ensure") } }

        func mark(_ file: URL) { FileManager.default.createFile(atPath: file.path, contents: Data()) }
    }

    private struct Launched {
        let services: AppServices
        let standIn: StandIn

        var view: DaemonConnectingView? { services.windows.controllers.first?.connectingView }

        func stop() {
            CmuxDialogCenter.shared.dismissAll()
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: standIn.root)
        }
    }

    private static func standInScript(_ standIn: StandIn, session: String) -> String {
        """
        #!/bin/sh
        line=""
        for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
        printf '%s\\n' "${line#?}" >> '\(standIn.log.path)'
        case " $* " in
        *" --version "*) echo 'cmux-tui 0.1.0'; exit 0 ;;
        *" server status "*) exit 1 ;;
        *" --replace-unresponsive "*)
            if [ -e '\(standIn.refuse.path)' ]; then
                echo '{"code":"server.replace_still_running","message":"cannot replace the unresponsive session owner","details":{},"retryable":false}' >&2
                exit 3
            fi
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

    /// The app's startup path (launch window, startup loop, first attempt) on the stand-in.
    private static func launch(stuck: Bool, refuse: Bool = false) throws -> Launched {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-restart-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let standIn = StandIn(root: root)
        if stuck { standIn.mark(standIn.stuck) }
        if refuse { standIn.mark(standIn.refuse) }
        let session = "cn-restart-\(UUID().uuidString.prefix(8).lowercased())"
        let binary = root.appendingPathComponent("cmux-tui")
        try standInScript(standIn, session: session).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        // As the app's launcher: bundled (so `--restore-progress`) with page origins (`--ws-loopback`).
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"),
                                 binaryIsBundled: true, webSocketPageOrigins: ["http://127.0.0.1:1"]),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })
        _ = NSApplication.shared
        let environment = AppEnvironment.current([:])
        let services = AppServices(environment: environment)
        services.windows.ordersWindowsIn = false
        // These tests press Restart themselves. The automatic restart (`UnresponsiveOwnerWatch`,
        // DaemonAutoRestartTests) would replace a stand-in that stayed stuck for 30 s on its own,
        // a second replace on a slow runner.
        services.daemon.recovery.restartsUnresponsiveOwner = { false }
        let prestart = DaemonPrestart(launcher: launcher, configuration: DaemonConnection.Configuration(terminalEnvironment: nil))
        services.daemon.start(launch: environment.launch, terminalEnvironment: [:], terminalEnvironmentProvider: { [:] },
                              prestart: prestart)
        services.windows.restoreWhenLoaded()
        return Launched(services: services, standIn: standIn)
    }

    /// Polls until `done` holds; only the suite's time limit (it cancels the test) ends a wait that
    /// never gets there. No wall-clock limit of its own: this loop and the app's own steps (the
    /// startup deadline's callback, the observation that shows a button) all run on the main
    /// actor, so on a starved runner the loop could wake past a wall limit before the step it
    /// waits for ran, and fail with that step already due (job 122242789085: "the launch window
    /// never showed the failure", 299 s into the run).
    private static func wait(until done: () -> Bool) async {
        while !done(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func control<T: NSView>(_ identifier: String, in view: NSView?, as type: T.Type) -> T? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier, let match = view as? T { return match }
        for subview in view.subviews {
            if let match = control(identifier, in: subview, as: type) { return match }
        }
        return nil
    }

    private static func shown(_ identifier: String, in view: NSView?) -> NSButton? {
        guard let button = control(identifier, in: view, as: NSButton.self), !button.isHiddenOrHasHiddenAncestor else { return nil }
        return button
    }

    /// The button's own target and action (a click outside an ordered-in window may never dispatch).
    private static func press(_ button: NSButton) throws {
        let action = try #require(button.action)
        _ = (try #require(button.target) as AnyObject).perform(action, with: button)
    }

    /// Waits for the launch window's failure (the startup deadline, 10 s, after a failed ensure),
    /// so a fixture that never got there fails here or at the suite's time limit.
    private static func unavailableView(_ launched: Launched) async throws -> DaemonConnectingView {
        await wait { launched.view?.state.isUnavailable == true }
        let view = try #require(launched.view, "the launch window never showed the connecting view")
        try #require(view.state.isUnavailable, "the launch window never showed the failure")
        return view
    }

    /// Presses Restart cmux-tui and confirms the question it asks.
    private static func restartAndConfirm(_ view: DaemonConnectingView) async throws {
        try press(try #require(shown("daemon.restart", in: view)))
        await wait { CmuxDialogCenter.shared.records.contains { $0.spec.identifier == "cmux.dialog.restartDaemon" } }
        let question = try #require(CmuxDialogCenter.shared.records.last { $0.spec.identifier == "cmux.dialog.restartDaemon" })
        #expect(!question.spec.lines.isEmpty)
        #expect(question.spec.cancelButton != nil)
        #expect(CmuxDialogCenter.shared.press(question.id, button: "restart"))
    }

    @Test func restartIsOfferedOnlyAfterAPlainEnsureFailedAndReplacesThenConnectsAgain() async throws {
        let launched = try Self.launch(stuck: false)
        defer { launched.stop() }
        let standIn = launched.standIn
        let view = try await Self.unavailableView(launched)

        // A start failure that is not a stuck owner (a spawn that failed, as on a full disk) offers
        // Restart too: no daemon runs, so the person needs a way out (restore fuzz h2). Until then
        // this asserted Restart hidden here, which left a full disk with nothing to press.
        await Self.wait { Self.shown("daemon.restart", in: view) != nil }
        let retry = Self.shown("daemon.retryNow", in: view)
        #expect(retry != nil)
        #expect(Self.shown("daemon.restart", in: view) != nil)
        #expect(standIn.ensures().allSatisfy { !$0.contains("--replace-unresponsive") })

        // The owner is stuck now: Retry Now asks again, and the failure still offers Restart.
        standIn.mark(standIn.stuck)
        let before = standIn.ensures().count
        try Self.press(try #require(retry))
        // Restart already shows, so wait for Retry Now's own ensure.
        await Self.wait { standIn.ensures().count > before }
        #expect(standIn.ensures().count > before)
        #expect(Self.shown("daemon.restart", in: view) != nil)

        try await Self.restartAndConfirm(view)
        await Self.wait {
            let ensures = standIn.ensures()
            guard let replace = ensures.firstIndex(where: { $0.contains("--replace-unresponsive") }) else { return false }
            return ensures[(replace + 1)...].contains { !$0.contains("--replace-unresponsive") }
        }
        let ensures = standIn.ensures()
        let replaceIndex = try #require(ensures.firstIndex { $0.contains("--replace-unresponsive") })
        let plain = try #require(ensures[..<replaceIndex].last)
        // The same ensure the app runs, plus the option.
        #expect(ensures[replaceIndex] == plain + ["--replace-unresponsive"])
        #expect(plain.contains("--restore-progress"))
        #expect(plain.contains("--ws-loopback"))
        // Then the app connects again (retryWake), with a plain ensure.
        #expect(ensures[(replaceIndex + 1)...].contains { !$0.contains("--replace-unresponsive") })
        #expect(ensures.filter { $0.contains("--replace-unresponsive") }.count == 1)
    }

    @Test func aRefusedRestartSaysSoAndLeavesRetry() async throws {
        let launched = try Self.launch(stuck: true, refuse: true)
        defer { launched.stop() }
        let standIn = launched.standIn
        let view = try await Self.unavailableView(launched)
        await Self.wait { Self.shown("daemon.restart", in: view) != nil }
        #expect(Self.shown("daemon.restart", in: view) != nil)

        try await Self.restartAndConfirm(view)
        let status = { Self.control("daemon.recoveryStatus", in: view, as: NSTextField.self) }
        await Self.wait {
            standIn.ensures().contains { $0.contains("--replace-unresponsive") } && status()?.isHidden == false
        }
        #expect(standIn.ensures().contains { $0.contains("--replace-unresponsive") })
        let shownStatus = try #require(status())
        #expect(!shownStatus.isHidden)
        #expect(!shownStatus.stringValue.isEmpty)
        #expect(!shownStatus.stringValue.contains("server.replace"))
        let retry = Self.shown("daemon.retryNow", in: view)
        #expect(retry != nil)
        #expect(retry?.isEnabled == true)
    }

    #if DEBUG
    /// The restore journey's daemon variants (scripts/cmux-next/restore-journey.py) read the
    /// recovery state through `debug.daemon` and press Restart through it, on the same path the
    /// button takes after its confirm: the stuck owner's launch window, then a replace.
    @Test func debugDaemonReportsTheRecoveryStateAndRestartsThroughIt() async throws {
        let launched = try Self.launch(stuck: true)
        defer { launched.stop() }
        let view = try await Self.unavailableView(launched)
        await Self.wait { Self.shown("daemon.restart", in: view) != nil }
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: launched.services.registry), settings: nil)
        // AppControl's wiring of `debug.daemon`.
        router.register([launched.services.daemon.debugControlMethod { [services = launched.services] in
            services.windows.controllers.map { (id: $0.state.id, shows: $0.recoveryShows) }
        }])
        func call(_ params: [String: CmuxNextSettings.JSONValue] = [:]) async throws -> [String: CmuxNextSettings.JSONValue] {
            try #require(try await router.handle(ControlRequest(id: "1", method: "debug.daemon", params: params)).get().objectValue)
        }

        let report = try await call()
        #expect(report["machine"] == .string("local"))
        #expect(report["startup"] == .string("unavailable"))
        #expect(report["startup_error"]?.stringValue?.isEmpty == false)
        let recovery = try #require(report["recovery"]?.objectValue)
        #expect(recovery["offers_restart"] == .bool(true))
        #expect(recovery["is_restarting"] == .bool(false))
        #expect(recovery["can_retry"] == .bool(true))
        let windowObjects = report["windows"]?.arrayValue?.compactMap { $0.objectValue }
        let windows = try #require(windowObjects)
        #expect(!windows.isEmpty)
        #expect(windows.allSatisfy { $0["shows"] == .string("connecting") }, "\(windows)")

        // Restart, as the button does after its confirm: the stand-in sees the replace.
        let started = try await call(["action": .string("restart")])
        #expect(started["action"] == .string("restart"))
        await Self.wait { launched.standIn.ensures().contains { $0.contains("--replace-unresponsive") } }
        #expect(launched.standIn.ensures().contains { $0.contains("--replace-unresponsive") })

        // Retry Now: one more plain ensure.
        let before = launched.standIn.ensures().count
        _ = try await call(["action": .string("retry")])
        await Self.wait { launched.standIn.ensures().count > before }
        #expect(launched.standIn.ensures().count > before)
        await #expect(throws: (any Error).self) { _ = try await call(["action": .string("explode")]) }
    }
    #endif
}
