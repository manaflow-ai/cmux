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
        defer { app.setActivationPolicy(policyBefore) }
        let launch = try await Launch()
        defer { try? FileManager.default.removeItem(at: launch.root) }
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
        await launch.shutDown()
    }

    @Test func noWindowIsAMenuBarAppAndAnOpeningWindowComesBackRegular() async throws {
        let app = NSApplication.shared
        let policyBefore = app.activationPolicy()
        defer { app.setActivationPolicy(policyBefore) }
        let launch = try await Launch()
        defer { try? FileManager.default.removeItem(at: launch.root) }
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

        await launch.shutDown()
    }
}
