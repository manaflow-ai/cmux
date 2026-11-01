import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Background mode (cx-ghagp, Leo 2026-10-13: "when cmux NEXT runs in the background it's still
/// visible: Dock icon and app switcher"). With no cmux window open the app keeps running as a
/// menu bar app: the accessory policy (no Dock icon, not in Cmd-Tab) and a menu bar item that
/// brings a window back. Any window opening makes it regular again before the window shows.
/// Driven like the launch: the process's adopted services, the real daemon, the registry actions.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct BackgroundAccessoryPolicyTests {
    /// Polls until `done` holds or `limit` passes (a poll, as in `FirstLaunchTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor private final class Presented {
        var policies: [NSApplication.ActivationPolicy] = []
    }

    /// A launch as `CmuxNextApp.main` and `AppDelegate` run it, on its own daemon and cmux.json.
    @MainActor private struct Launch {
        let services: AppServices
        let settings: SettingsController
        let configURL: URL
        let root: URL
        let owner: AppTestDaemonOwner
        let presented = Presented()

        init() async throws {
            let binary = try #require(SameTreeDaemonBinary.url)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-bg-\(UUID().uuidString.prefix(8))")
            let session = "cn-bg-\(UUID().uuidString.prefix(8).lowercased())"
            let launcher = DaemonLauncher(
                configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"), exitWithProcess: ProcessInfo.processInfo.processIdentifier),
                environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
            owner = AppTestDaemonOwner(launcher)
            // Finish throwing filesystem setup before adopting services into the process.
            configURL = root.appendingPathComponent("cmux.json")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: configURL)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            // As `CmuxNextApp.main` and `AppDelegate` launch: regular, and these services are the process's.
            NSApplication.shared.setActivationPolicy(.regular)
            services = AppServices(environment: AppEnvironment.current([:]))
            AppProcessRoot.shared.adopt(services)
            settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: configURL,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            AppActions.bind(services)
            services.palette.bindRegistryActions()
            services.windows.ordersWindowsIn = false
            // The policy each window is presented under (the hook runs after it is ordered in).
            let presented = presented
            services.windows.onPresent = { _ in presented.policies.append(NSApp.activationPolicy()) }
            services.daemon.start { [owner] in
                DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: owner.endpointProvider)
            }
        }

        @discardableResult
        func shutDown() async -> Bool {
            let reaped = await owner.stop(services)
            for controller in services.windows.controllers { controller.window?.close() }
            for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
            let panels = NSApp.windows.filter { services.palette.owns($0) }
            services.palette.hide()
            for panel in panels { panel.close() }
            // Leave background mode as a window opening does: its menu bar item goes.
            services.background.windowWillAppear(activates: false)
            return reaped
        }
    }

    /// Always await daemon shutdown and close the app's windows/status item, including when
    /// a requirement or file write throws. The caller's activation-policy defer runs afterward.
    private static func withLaunch(_ body: (Launch) async throws -> Void) async throws {
        // A test process may have no root yet. Its inert replacement owns no windows or actions.
        let previous = AppProcessRoot.shared.services ?? AppServices(environment: AppEnvironment.current([:]))
        let launch = try await Launch()
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: launch.root) } }
        let result: Result<Void, any Error>
        do { result = .success(try await body(launch)) }
        catch { result = .failure(error) }
        // Disable this launch's background eligibility before closing windows: a queued settle
        // must not recreate the status item after shutDown or change the restored activation policy.
        AppProcessRoot.shared.adopt(previous)
        reaped = await launch.shutDown()
        try result.get()
    }

    /// The window closed while the restore still runs stays closed: the restore neither opens it
    /// again nor lands the first workspace in a new one. The launch window is the one on screen then.
    @Test func aWindowClosedBeforeTheRestoreFinishesStaysClosed() async throws {
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        defer { app.setActivationPolicy(policyBefore) }
        try await Self.withLaunch { launch in
            let windows = launch.services.windows
            windows.restoreWhenLoaded()
            try #require(!windows.restored, "the restore finished before the launch window could close")
            try #require(windows.controllers.count == 1, "no launch window")
            _ = launch.services.registry.perform("closeAllWindows", invocation: ActionInvocation(origin: .user))
            #expect(windows.controllers.isEmpty)
            launch.presented.policies = []
            await Self.wait(within: .seconds(90)) { windows.restored && !windows.registry.isLaunching }
            try #require(windows.restored, "the restore never finished")
            // A reopened window would land on the next main-actor turns; test-only wait.
            try? await Task.sleep(for: .milliseconds(500))
            #expect(launch.presented.policies.isEmpty, "the restore presented a closed window, even if only for a moment")
            #expect(windows.controllers.isEmpty, "the restore opened \(windows.controllers.count) window(s) after the user closed the launch window")
        }
    }

    /// A window delegate that refuses its close, as an incognito window does when the person cancels
    /// its close confirmation: `windowShouldClose` says no, and nothing follows.
    @MainActor private final class RefusedClose: NSObject, NSWindowDelegate {
        var asked = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            asked += 1
            return false
        }
    }

    /// Review of #27258: a close the window refuses while the restore runs (a cancelled incognito
    /// confirmation) is no close. The restore remembers nothing of it and keeps the window open; only
    /// a close AppKit carries out (`windowWillClose`) counts as the person's.
    @Test func aCloseTheWindowRefusesDuringTheRestoreKeepsItOpen() async throws {
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        defer { app.setActivationPolicy(policyBefore) }
        try await Self.withLaunch { launch in
            let windows = launch.services.windows
            windows.restoreWhenLoaded()
            try #require(!windows.restored, "the restore finished before the launch window could close")
            let controller = try #require(windows.controllers.first, "no launch window")
            let window = try #require(controller.window)
            let refusal = RefusedClose()
            window.delegate = refusal
            defer { window.delegate = controller }
            _ = launch.services.registry.perform("closeAllWindows", invocation: ActionInvocation(origin: .user))
            window.delegate = controller
            try #require(refusal.asked == 1, "Close All Windows did not ask the window")
            #expect(windows.controllers.contains { $0 === controller }, "the refused close closed the window")
            #expect(windows.restoreClosed.windows.isEmpty, "the refused close was remembered as closed: \(windows.restoreClosed.windows)")
            #expect(windows.closedLaunchWindowID == nil, "the refused close was remembered as the closed launch window")
            await Self.wait(within: .seconds(90)) { windows.restored && !windows.registry.isLaunching }
            try #require(windows.restored, "the restore never finished")
            #expect(!windows.controllers.isEmpty, "the restore tore down the window whose close was refused")
            #expect(windows.registry.value.windows.contains(where: \.isOpen),
                    "the restore registered no open window: \(windows.registry.value.windows.map { ($0.id, $0.isOpen) })")
        }
    }

    @MainActor private final class HeldReports {
        var batches = 0
    }

    /// The restore's first workspace can be reported after the restore ended: the create's reply comes
    /// before the store applies the event that lists it (1 run in 3 on cmux12s, job 691124a2e9b4323980de7e07).
    /// The store holds that report here until the restore ended, so the order is certain, not a race. The
    /// launch window the person closed stays closed: the workspace waits in it, and no window shows.
    @Test func aWorkspaceTheRestoreAskedForReportedAfterItEndedStaysInTheClosedLaunchWindow() async throws {
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        defer { app.setActivationPolicy(policyBefore) }
        try await Self.withLaunch { launch in
            let windows = launch.services.windows
            let store = launch.services.daemon.store
            defer { store.eventHold = nil }
            let held = HeldReports()
            store.eventHold = { batch in
                guard batch.contains(where: { if case .workspaceAdded = $0.event { true } else { false } }) else { return false }
                held.batches += 1
                return true
            }
            windows.restoreWhenLoaded()
            try #require(!windows.restored, "the restore finished before the launch window could close")
            try #require(windows.controllers.count == 1, "no launch window")
            _ = launch.services.registry.perform("closeAllWindows", invocation: ActionInvocation(origin: .user))
            #expect(windows.controllers.isEmpty)
            launch.presented.policies = []
            await Self.wait(within: .seconds(90)) { windows.restored && !windows.restoring }
            try #require(windows.restored && !windows.restoring, "the restore never finished")
            try #require(store.workspaces.isEmpty, "the restore's workspace was listed before the restore ended: \(store.workspaces.map(\.id))")
            try #require(held.batches > 0, "the daemon reported no new workspace while the restore ran")

            // The daemon's report arrives now; reconcile runs in this apply.
            store.releaseHeldEvents()
            let reported = store.workspaces.map(\.id)
            try #require(!reported.isEmpty, "the held report listed no workspace")
            // A window it opened would be presented in this turn or the next ones; test-only wait.
            try? await Task.sleep(for: .milliseconds(500))
            let registry = windows.registry.value
            #expect(launch.presented.policies.isEmpty, "the late workspace presented a window after the user closed the launch window")
            #expect(windows.controllers.isEmpty, "the late workspace opened \(windows.controllers.count) window(s) after the user closed the launch window")
            #expect(reported.allSatisfy { registry.owner(of: $0).flatMap { registry.window($0) }?.isOpen == false },
                    "the late workspace is not in a closed window: \(registry.windows.map { ($0.id, $0.isOpen, $0.workspaceIDs) })")
            #expect(windows.closedLaunchWindowID == nil, "the closed launch window is still remembered after its workspace arrived")
        }
    }

    @Test func noWindowIsAMenuBarAppAndAnOpeningWindowComesBackRegular() async throws {
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        defer { app.setActivationPolicy(policyBefore) }
        try await Self.withLaunch { launch in
            let services = launch.services
            let settings = launch.settings
            let configURL = launch.configURL
            let presented = launch.presented
            services.windows.restoreWhenLoaded()
            let windows = services.windows
            let hasWindow = { windows.active.flatMap { windows.registry.members(of: $0.state.id).first } != nil }
            await Self.wait(within: .seconds(90), until: hasWindow)
            try #require(hasWindow(), "the launch window never showed a workspace")
            #expect(app.activationPolicy() == .regular, "a window is open")

            // The user closes the last window (Close All Windows): the app keeps running, off the Dock.
            _ = services.registry.perform("closeAllWindows", invocation: ActionInvocation(origin: .user))
            await Self.wait(within: .seconds(5)) { app.activationPolicy() == .accessory }
            #expect(windows.controllers.isEmpty)
            #expect(app.activationPolicy() == .accessory, "no window open: no Dock icon and no Cmd-Tab entry")

            // Show cmux (the Dock click's and the menu bar item's path): the window comes back, regular first.
            presented.policies = []
            _ = services.registry.perform("showMainWindow", invocation: ActionInvocation(origin: .user))
            await Self.wait(within: .seconds(30)) { !presented.policies.isEmpty }
            #expect(windows.controllers.count == 1, "Show cmux opened no window")
            #expect(app.activationPolicy() == .regular)
            #expect(presented.policies == [.regular], "a window was ordered in under \(presented.policies)")

            // Settings opened while in the background opens it in a window, so the app is regular again.
            _ = services.registry.perform("closeAllWindows", invocation: ActionInvocation(origin: .user))
            await Self.wait(within: .seconds(5)) { app.activationPolicy() == .accessory }
            #expect(app.activationPolicy() == .accessory)
            presented.policies = []
            _ = services.registry.perform("openSettings", invocation: ActionInvocation(origin: .user))
            await Self.wait(within: .seconds(30)) { !presented.policies.isEmpty }
            #expect(windows.controllers.count == 1, "Settings opened no window")
            #expect(app.activationPolicy() == .regular)
            #expect(presented.policies == [.regular], "the Settings window was ordered in under \(presented.policies)")

            // `app.hideDockIconWithoutWindows: false` keeps the old behavior: regular with no window.
            try Data(#"{"app":{"hideDockIconWithoutWindows":false}}"#.utf8).write(to: configURL)
            await settings.reload()
            #expect(settings.snapshot.hideDockIconWithoutWindows == false)
            _ = services.registry.perform("closeAllWindows", invocation: ActionInvocation(origin: .user))
            await Self.wait(within: .seconds(5)) { windows.controllers.isEmpty }
            // A background switch would land on the next main-actor turn; test-only wait.
            try? await Task.sleep(for: .milliseconds(500))
            #expect(windows.controllers.isEmpty)
            #expect(app.activationPolicy() == .regular, "the setting is off: the Dock icon stays with no window")
        }
    }
}
