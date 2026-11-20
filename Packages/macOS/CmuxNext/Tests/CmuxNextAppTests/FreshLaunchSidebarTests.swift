import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo's first-frame call (BACKLOG "Ideas"): a launch never shows glass alone. On a fresh profile
/// nothing is saved, so the launch window opens on the empty main pane beside the sidebar
/// (cx-r650e) while cmux-tui starts. The sidebar has nothing better to wait for: it shows in the
/// window's first frame, not after the first workspace arrives. Driven like the launch: a fresh
/// session, the real daemon, the app's launch window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct FreshLaunchSidebarTests {
    @MainActor private final class Presented {
        var sidebarShown: [Bool] = []
    }

    @Test func aFreshProfilesLaunchWindowShowsItsSidebarFromItsFirstFrame() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-fresh-\(UUID().uuidString.prefix(8))")
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: root) } }
        let session = "cn-fresh-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"), exitWithProcess: ProcessInfo.processInfo.processIdentifier),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let owner = AppTestDaemonOwner(launcher)
        _ = NSApplication.shared
        let reveal = LaunchReveal(deadline: .seconds(60))
        let services = AppServices(environment: AppEnvironment.current([:]), launchReveal: reveal)
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
            let panels = NSApp.windows.filter { services.palette.owns($0) }
            services.palette.hide()
            for panel in panels { panel.close() }
        }
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        // Whether the sidebar is shown as each window is presented (the hook runs as it is ordered in).
        let presented = Presented()
        services.windows.onPresent = { _ in presented.sidebarShown.append(reveal.isReady(.sidebar)) }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: owner.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let result: Result<Void, any Error>
        do {
            try Task.checkCancellation()
            let deadline = ContinuousClock.now + .seconds(30)
            while presented.sidebarShown.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            result = .success(())
        } catch { result = .failure(error) }

        // stop() joins its uncancelled teardown before any failure escapes and the defers
        // close windows and remove the state directory, including cancellation before connection.
        reaped = await owner.stop(services)
        try result.get()

        #expect(presented.sidebarShown.first == true, "the launch window opened with its sidebar held clear: glass alone")
    }
}
