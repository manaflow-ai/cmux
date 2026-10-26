import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Background mode (cx-ghagp, Leo 2026-10-13: "when cmux NEXT runs in the background it's still
/// visible: Dock icon and app switcher"). With no cmux window open the app keeps running as a
/// menu bar app: the accessory policy (no Dock icon, not in Cmd-Tab) and a menu bar item that
/// brings a window back. Any window opening makes it regular again before the window shows.
/// Driven like the launch: the process's adopted services, the real daemon, the registry actions.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
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

    @Test func noWindowIsAMenuBarAppAndAnOpeningWindowComesBackRegular() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-bg-\(UUID().uuidString.prefix(8))")
        let session = "cn-bg-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        // As `CmuxNextApp.main` and `AppDelegate` launch: regular, and these services are the process's.
        app.setActivationPolicy(.regular)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppProcessRoot.shared.adopt(services)
        // A cmux.json of its own (Settings needs one loaded), with the setting unset: on.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("cmux.json")
        try Data("{}".utf8).write(to: configURL)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: configURL,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        // The policy each window is presented under (the hook runs after it is ordered in).
        let presented = Presented()
        services.windows.onPresent = { _ in presented.policies.append(NSApp.activationPolicy()) }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer {
            app.setActivationPolicy(policyBefore)
            try? FileManager.default.removeItem(at: root)
        }
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

        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
    }
}
