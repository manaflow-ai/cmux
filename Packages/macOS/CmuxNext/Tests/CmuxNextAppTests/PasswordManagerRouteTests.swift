import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Settings > Browser > Autofill and passwords (Lawrence 2026-10-28: "use native chrome UIs and
/// functionality for both of them"): the person's password manager and contact info are Chromium's
/// own pages, in a Chromium tab of the browser profile, backed by the same stores the save prompt
/// and autofill write. `chrome://password-manager` and `chrome://settings/passwords` load
/// Chromium's page (they no longer open a cmux page), Manage Passwords and Manage Addresses open
/// it in the profile they name, and the palette's Passwords opens Chromium's page too. Runs the
/// app's action registry against a same-tree cmux-tui daemon, as the palette and the Settings
/// page reach it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PasswordManagerRouteTests {
    @Test(arguments: ["chrome://password-manager/passwords", "chrome://settings/passwords"])
    func chromiumsPasswordManagerOpensInAChromiumTab(_ address: String) async throws {
        try await Self.withApp { services, _ in
            let invocation = ActionInvocation(arguments: ["url": .string(address)])
            #expect(services.registry.perform("openBrowser", invocation: invocation))
            try await Self.until({ Self.chromiumTab(services, address) != nil },
                                 report: { "tabs: \(Self.tabs(services).map { "\($0.url ?? "-") \($0.browserEngine ?? "-")" })" })
        }
    }

    @Test(arguments: [("browserProfile.managePasswords", "chrome://password-manager/passwords"),
                      ("browserProfile.manageAddresses", "chrome://settings/addresses")])
    func manageOpensChromiumsPageInTheProfile(_ action: String, _ address: String) async throws {
        try await Self.withApp { services, _ in
            let profile = try #require(services.browserProfiles.ordered.first)
            #expect(services.registry.descriptor(for: ActionID(action)) != nil, "\(action) is not an action")
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .browserProfile, id: profile.id), origin: .user)
            #expect(services.registry.perform(ActionID(action), invocation: invocation))
            try await Self.until({ Self.chromiumTab(services, address).map(services.browserProfiles.profileID(ofTab:)) == profile.id },
                                 report: { "tabs: \(Self.tabs(services).map { "\($0.url ?? "-") \($0.browserEngine ?? "-")" })" })
        }
    }

    @Test func palettePasswordsOpensChromiumsPasswordManager() async throws {
        try await Self.withApp { services, _ in
            #expect(services.registry.perform("passwords.open"))
            try await Self.until({ Self.chromiumTab(services, "chrome://password-manager/passwords") != nil },
                                 report: { "tabs: \(Self.tabs(services).map { "\($0.url ?? "-") \($0.browserEngine ?? "-")" })" })
        }
    }

    /// A Chromium tab whose address is `address` (or a page under it, as Chromium redirects).
    static func chromiumTab(_ services: AppServices, _ address: String) -> TabModel? {
        tabs(services).first { $0.browserEngine == BrowserEngineTag.cef.rawValue && ($0.url?.hasPrefix(address) ?? false) }
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
    static func withApp(home: String = NSHomeDirectory(), _ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-pwroute-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-pwroute-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
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
        // Stop the app's connection first: on the daemon's EOF it would start a
        // fresh daemon that outlives the test. The shutdown uses its own socket.
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        try result.get()
    }
}
