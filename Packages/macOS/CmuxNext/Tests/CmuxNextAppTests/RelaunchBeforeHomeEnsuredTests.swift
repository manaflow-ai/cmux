import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextTestSupport
import Foundation
import Testing

/// "A relaunch reopens exactly where the person was, Home included" (Leo). cmux#44491 moved
/// `home.start()` (whose connect observation sends `ensure_home`) after the launch's first frame,
/// and the restore can reach `FirstWorkspaceLaunch.create` before it: `awaitHomeEnsured` returns at
/// once with nothing in flight, Home is not known yet, and a tree of Home alone looks empty, so the
/// launch made a New Tab workspace and showed it instead of the saved front (fleet launch runs, 2 of
/// 3; later relaunches reopened that new workspace).
///
/// The boundary: the app's services on a real same-tree daemon. The first launch runs Home as the
/// app always did (ensured before its restore), sets the front, saves and quits keeping the daemon.
/// The relaunch holds Home back (the seam: this harness never calls `home.start()`, so the test
/// sends `ensure_home` itself, `HomeService.ensureHomeWorkspace`, the call `home.start()` makes on
/// connect) until the restore has ended, or has waited for Home for a few seconds, whichever is
/// first. The front window must show the saved workspace and tab, and no workspace may be made.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RelaunchBeforeHomeEnsuredTests {
    /// What the front window showed at quit.
    private struct Saved {
        var window: String
        var workspace: String
        var tab: String?
        var workspaces: Set<String>
    }

    /// The saved front is a workspace of the person's own (a terminal tab).
    @Test func aRelaunchBeforeHomeIsEnsuredReopensTheSavedWorkspace() async throws {
        try await Self.relaunchHoldingHome { before in
            let window = try #require(before.windows.active)
            let workspace = try #require(await before.windows.createWorkspace(into: window.state.id))
            try await Self.until({ window.state.workspaceID == workspace && window.focusedPane?.currentTabKey != nil },
                                 report: { Self.report(before) })
        }
    }

    /// The saved front is Home, the person's only workspace (the case the fleet runs hit).
    @Test func aRelaunchBeforeHomeIsEnsuredReopensHome() async throws {
        try await Self.relaunchHoldingHome { before in
            let window = try #require(before.windows.active)
            let home = try #require(before.home.homeWorkspace)
            try await Self.until({ window.state.workspaceID == home.id }, report: { Self.report(before) })
            try #require(before.daemon.store.workspaces.needsFirstWorkspace(leftover: [], home: before.home.homeWorkspaceID),
                         "fixture: Home is not the only workspace: \(Self.report(before))")
        }
    }

    /// First launch (Home ensured before restore, as the app did before #44491), `front` sets the
    /// front window, save and quit keeping the daemon; then a relaunch with Home held back, checked.
    private static func relaunchHoldingHome(front: (AppServices) async throws -> Void) async throws {
        try await withDaemon { launcher in
            let before = try await launch(launcher, holdingHome: false)
            var saved: Saved?
            let seeded = await capture {
                try await front(before)
                let window = try #require(before.windows.active)
                saved = Saved(window: window.state.id, workspace: try #require(window.state.workspaceID),
                              tab: window.focusedPane?.currentTabKey, workspaces: Set(before.daemon.store.workspaces.map(\.id)))
                await before.windows.prepareForTermination()
                let records = await before.daemon.windowState?.document.windows ?? []
                #expect(records.contains { $0.id == window.state.id && !$0.isClosed }, "no open record for the front window: \(records.map(\.id))")
            }
            await quit(before, endingDaemon: (try? seeded.get()) == nil)
            try seeded.get()
            let front = try #require(saved)

            let after = try await launch(launcher, holdingHome: true)
            let restored = await capture {
                let window = try #require(after.windows.controller(for: front.window), "the front window did not come back: \(report(after))")
                #expect(window.state.workspaceID == front.workspace,
                        "the front window shows \(window.state.workspaceID ?? "nothing"), saved \(front.workspace): \(report(after))")
                if let tab = front.tab {
                    #expect(window.focusedPane?.currentTabKey == tab, "the front tab is \(window.focusedPane?.currentTabKey ?? "nil"), saved \(tab)")
                }
                let made = Set(after.daemon.store.workspaces.map(\.id)).subtracting(front.workspaces)
                #expect(made.isEmpty, "the relaunch made workspaces \(made.sorted())")
                #expect(after.windows.registry.value.recency.first == front.window,
                        "the front window is \(after.windows.registry.value.recency.first ?? "none"), was \(front.window)")
            }
            await quit(after, endingDaemon: true)
            try restored.get()
        }
    }

    /// The app's services on `launcher`'s daemon, once restore ended and Home is known. Not
    /// `holdingHome`: `ensure_home` is in flight before the restore starts. `holdingHome`: it is
    /// sent once the restore ended, or once it has run 3 s (a restore that waits for Home).
    private static func launch(_ launcher: DaemonLauncher, holdingHome: Bool) async throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.ensure.ensuresAtLaunch = true // as AppDelegate: the launch starts Home, maybe after its first frame
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        let local = services.machines.local
        do {
            if !holdingHome {
                try await until({ local.supports(DaemonCapability.workspaceKind.rawValue) && local.connection != nil }, within: .seconds(90))
                services.home.ensureHomeWorkspace(try #require(local.connection))
            }
            services.windows.restoreWhenLoaded()
            if holdingHome {
                var restoringSince: ContinuousClock.Instant?
                try await until({
                    if services.windows.restoring, restoringSince == nil { restoringSince = .now }
                    return services.windows.restored || restoringSince.map { ContinuousClock.now - $0 > .seconds(3) } == true
                }, within: .seconds(90), report: { report(services) })
                try #require(local.supports(DaemonCapability.workspaceKind.rawValue))
                services.home.ensureHomeWorkspace(try #require(local.connection))
            }
            try await until({ services.windows.restored && !services.windows.restoring && !services.windows.registry.isLaunching
                    && services.daemon.windowState != nil && services.home.homeWorkspace != nil && services.windows.active?.state.workspaceID != nil },
                            within: .seconds(90), report: { "\(services.home.homeWorkspaceStep); \(report(services))" })
            // A landing after the restore (FirstWorkspaceLaunch.land, a late create) has its turn; test-only wait.
            try? await Task.sleep(for: .seconds(1))
        } catch {
            await quit(services, endingDaemon: true)
            throw error
        }
        return services
    }

    private static func report(_ services: AppServices) -> String {
        let windows = services.windows.controllers.map { "\($0.state.id): ws \($0.state.workspaceID ?? "nil") tab \($0.focusedPane?.currentTabKey ?? "nil")" }
        let workspaces = services.daemon.store.workspaces.map { "\($0.id)(\($0.kind ?? "-"))" }
        return "windows [\(windows.joined(separator: ", "))] recency \(services.windows.registry.value.recency) workspaces \(workspaces) "
            + "home \(services.home.homeWorkspace?.id ?? "nil")"
    }

    private static func quit(_ services: AppServices, endingDaemon: Bool) async {
        services.closeWindowsForTest()
        guard let connection = services.daemon.connection else { return }
        services.daemon.shutdownConnection()
        await connection.close()
        if endingDaemon { _ = try? await connection.shutdownDaemon(endTerminals: true) }
    }

    private static func capture(_ body: () async throws -> Void) async -> Result<Void, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func withDaemon(_ body: (DaemonLauncher) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-rh-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-rh-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        try await body(launcher)
    }

    private static func until(_ condition: () async throws -> Bool, within timeout: Duration = .seconds(20),
                              report: () async -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        // test-poll: the condition spans AppKit windows and a daemon round trip with no single signal
        while !(try await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let met = try await condition()
        let detail = met ? "" : await report()
        try #require(met, "timed out: \(detail)", sourceLocation: sourceLocation)
    }
}
