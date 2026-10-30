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
        let session = "cn-fresh-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let reveal = LaunchReveal(deadline: .seconds(60))
        let services = AppServices(environment: AppEnvironment.current([:]), launchReveal: reveal)
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        // Whether the sidebar is shown as each window is presented (the hook runs as it is ordered in).
        let presented = Presented()
        services.windows.onPresent = { _ in presented.sidebarShown.append(reveal.isReady(.sidebar)) }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer { try? FileManager.default.removeItem(at: root) }
        let deadline = ContinuousClock.now + .seconds(30)
        while presented.sidebarShown.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }

        #expect(presented.sidebarShown.first == true, "the launch window opened with its sidebar held clear: glass alone")
    }
}
