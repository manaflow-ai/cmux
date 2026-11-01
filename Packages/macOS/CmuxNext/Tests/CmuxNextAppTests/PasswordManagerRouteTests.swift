import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// cx-d0d.76, decision CHROME-INTERNAL-PAGES P4: Chromium's own password
/// manager (`chrome://password-manager`, `chrome://settings/passwords`)
/// exports passwords past `browser.passwords.allowExport`, so a person's
/// path there opens cmux's Passwords page instead, as `chrome://settings`
/// opens Settings. Runs the app's action registry against a same-tree
/// cmux-tui daemon, as New Browser Tab with a URL reaches it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PasswordManagerRouteTests {
    @Test(arguments: ["chrome://password-manager/passwords", "chrome://settings/passwords"])
    func chromiumsPasswordManagerOpensCmuxsPasswordsPage(_ address: String) async throws {
        try await Self.withApp { services, _ in
            let invocation = ActionInvocation(arguments: ["url": .string(address)])
            #expect(services.registry.perform("openBrowser", invocation: invocation))
            // A store page tab, or an app-only one while the daemon cannot hold page tabs yet.
            try await Self.until({ services.pages.window(showing: .passwords, windows: services.windows.controllers) != nil },
                                 report: { WindowStateReport.describe(services, page: .passwords) })
            #expect(!Self.tabs(services).contains { $0.url?.contains("password") == true && $0.page == nil },
                    "Chromium's password manager opened in a browser tab")
        }
    }

    static func tabs(_ services: AppServices) -> [TabModel] {
        services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
    }

    /// Polls `condition` (the store follows the daemon's events) up to a deadline.
    /// A timeout is reported at the caller's line, with `report`.
    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(20),
                      report: () -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out: \(report())", sourceLocation: sourceLocation)
    }

    /// The app's services on a fresh same-tree daemon, ready once restore made its first terminal.
    /// `home` is the daemon's HOME (where it reads its Ghostty config).
    static func withApp(home: String = NSHomeDirectory(), agentPaneEnvironment: [String: String]? = nil,
                        _ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-pwroute-\(UUID().uuidString.prefix(8))")
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: root) } }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-pwroute-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state"), exitWithProcess: ProcessInfo.processInfo.processIdentifier),
            environment: { ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let owner = AppTestDaemonOwner(launcher)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: agentPaneEnvironment)
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: owner.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        // Registered before restore can suspend or fail, including before the test body starts.
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
            let panels = NSApp.windows.filter { services.palette.owns($0) }
            services.palette.hide()
            for panel in panels { panel.close() }
        }
        let result: Result<Void, any Error>
        do {
            try await until({ services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }, within: .seconds(90))
            // Actions reach tabs through the window's panes, which attach after the daemon's.
            try await until({ services.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(30))
            // The window can show its workspace before restore ends, and restore's last step lands
            // the launch's first workspace (`FirstWorkspaceLaunch.land`), which takes the window
            // off any top page a test showed before then. Wait until restore has run to the end.
            try await until({ !services.windows.registry.isLaunching }, within: .seconds(30))
            result = .success(try await body(services, try #require(services.daemon.connection)))
        } catch { result = .failure(error) }
        reaped = await owner.stop(services)
        try result.get()
    }
}
