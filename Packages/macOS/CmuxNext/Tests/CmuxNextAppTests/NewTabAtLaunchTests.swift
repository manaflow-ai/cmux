import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A new workspace asked for while the app still connects to cmux-tui (dogfood gate v2.2.3, journey
/// `type`, failed about 1 run in 8 on v2.2.2 and v2.2.3): `newTab` ran the moment the app's socket
/// answered, the daemon made the workspace and its terminal, but the window kept showing Home with
/// "No workspaces" in its sidebar, and the keys typed next went to the Chief composer.
///
/// Until restore registers it, the launch window is outside the registry, so New Workspace's target
/// (`targetWindow(preferring:)`) was a new window id: the workspace was claimed for a second window,
/// and the launch window, which the person sees, got only Home.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows)
struct NewTabAtLaunchTests {
    /// The workspace `newTab` asks for, under the key its create sends.
    private static let created = "k-new-at-launch"

    /// The first snapshot after the create: Home (listed first, as a fresh session lists it) and the new workspace.
    private static func tree() -> DaemonTree {
        DaemonTree(workspaces: [homeOnly().workspaces[0],
                                WorkspaceSnapshot(id: 2, key: WorkspaceKey(rawValue: created), name: "jr-type",
                                                  screens: [ScreenSnapshot(id: 2, layout: .leaf(2), panes: [
                                                      PaneSnapshot(id: 2, name: "Main", tabs: [TabSnapshot(surface: 1, title: "zsh", cwd: "/tmp")]),
                                                  ])])])
    }

    /// Home only: the store before the asked-for workspace is created.
    private static func homeOnly() -> DaemonTree {
        var home = WorkspaceSnapshot(id: 1, key: "k-home", name: "Home",
                                     screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [
                                         PaneSnapshot(id: 1, name: "Main", tabs: [TabSnapshot(surface: 2, title: "Chief", cwd: "/tmp")]),
                                     ])])
        home.kind = "home"
        return DaemonTree(workspaces: [home])
    }

    /// The app with its launch window up in the connecting state (no daemon, so the restore never
    /// runs): the window is outside the registry, as it is until the restore registers it.
    private static func launchWindowUp() throws -> (AppServices, WindowController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.windows.restoreWhenLoaded()
        let launch = try #require(services.windows.controllers.first)
        try #require(services.windows.launchWindowID == launch.state.id && services.windows.registry.value.window(launch.state.id) == nil,
                     "no launch window outside the registry: the test does not start where the bug was")
        return (services, launch)
    }

    /// New Workspace's target while the app connects (`AppActions.newWorkspace`: the active window's) is the
    /// launch window, never a new window id beside it.
    @Test func newWorkspaceWhileConnectingTargetsTheLaunchWindow() throws {
        let (services, launch) = try Self.launchWindowUp()
        defer { for controller in services.windows.controllers { controller.window?.close() } }

        #expect(services.windows.targetWindow(preferring: services.windows.active?.state.id) == launch.state.id,
                "New Workspace while connecting targets a second window, not the launch window")
    }

    /// The real create runs a reconcile before it sends the create command (`FirstTabHold.creating` releases at
    /// once for a terminal), with Home already listed: that reconcile registers the launch window early. The
    /// workspace's own delta came next and its reconcile placed the claim in the registry the restore then
    /// replaces with the saved one (a relaunch with saved windows lost it to another window, unselected).
    /// The claim stays pending until the restore's own reconcile places it.
    @Test func aClaimOnTheLaunchWindowSurvivesTheReconcilesBeforeTheRestore() throws {
        let (services, launch) = try Self.launchWindowUp()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        services.windows.claimNew(workspaceID: Self.created, window: target)

        // In one main-actor turn, before the restore task runs: the release's reconcile, then the workspace's delta.
        services.daemon.store.apply(snapshot: Self.homeOnly())
        services.windows.reconcileMembership()
        services.daemon.store.apply(snapshot: Self.tree())
        services.windows.reconcileMembership()

        #expect(services.windows.registry.value.owner(of: Self.created) == nil,
                "a reconcile before the restore placed the launch window's claim in the registry the restore replaces")
        #expect(services.windows.claims.pending[Self.created] == launch.state.id,
                "the claim is not the launch window's, or a reconcile before the restore dropped it")
    }

    /// With saved windows and no launch snapshot, the launch window opens under a new id and restore gives
    /// it the frontmost saved window's id (`adoptLaunchWindow`). A workspace claimed for it meanwhile goes
    /// with it: a claim left on the old id would open a second window under that id.
    @Test func aClaimOnTheLaunchWindowFollowsItsAdoptedIdentity() throws {
        let (services, launch) = try Self.launchWindowUp()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        services.windows.claimNew(workspaceID: Self.created, window: target, frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        services.windows.launchWindowAdopted(from: launch.state.id, as: "saved-front")

        #expect(services.windows.claims.pending[Self.created] == "saved-front")
        #expect(services.windows.pendingFrames[launch.state.id] == nil && services.windows.pendingFrames["saved-front"] != nil)
    }

    /// A script's create without `focus` (no view change) during the launch files the workspace into the
    /// launch window without showing it, as it does for any open window (a quiet claim), and never sends the
    /// launch window, the one the person looks at, behind the others.
    @Test func aQuietCreateAtLaunchFilesItsWorkspaceWithoutSendingTheWindowBehind() throws {
        let (services, launch) = try Self.launchWindowUp()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            services.windows.claimNew(workspaceID: Self.created, window: target)
        }

        #expect(target == launch.state.id, "a quiet create while connecting opens a second window")
        #expect(services.windows.behindWindows.isEmpty, "a quiet create at launch sends a window behind: \(services.windows.behindWindows)")
        #expect(services.windows.claims.quiet.contains(Self.created), "a quiet create at launch would be shown on arrival")
    }

    /// End to end on the real daemon, as the `type` journey runs it: `newTab` sent once the app's connection
    /// exists and before the restore ran. After the restore, the launch window is the only window and shows
    /// the new workspace; the first launch's landing (Home) does not take the window back from it.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aWorkspaceAskedForWhileConnectingShowsInTheLaunchWindow() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-newtab-launch-\(UUID().uuidString.prefix(8))")
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: root) } }
        let session = "cn-ntl-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state"),
                                 exitWithProcess: ProcessInfo.processInfo.processIdentifier),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let owner = AppTestDaemonOwner(launcher)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: owner.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let windows = services.windows, store = services.daemon.store
        let name = "jr-type-\(UUID().uuidString.prefix(6).lowercased())"
        let result: Result<Void, any Error>
        do {
            let launch = try #require(windows.controllers.first)
            // The app's socket answered: the create can be sent. The restore has not run yet.
            try await Self.until(.seconds(60)) { services.daemon.connection != nil || windows.restored }
            try #require(services.daemon.connection != nil && !windows.restored,
                         "the restore ran before the app could ask for a workspace: the test does not start where the bug was")
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(name), "focus": .bool(true)],
                                                                                 origin: .cli))
            func made() -> String? { store.workspaces.first { $0.name == name }?.id }
            try await Self.until(.seconds(60)) {
                windows.restored && !windows.restoring && !windows.registry.isLaunching
                    && made().map { windows.registry.value.owner(of: $0) != nil } == true
            }
            let workspace = try #require(made(), "the asked-for workspace was never made")
            let registered = windows.registry.value.windows

            #expect(registered.filter(\.isOpen).count == 1, "a second window took the new workspace: \(registered.map { "\($0.id): \($0.workspaceIDs)" })")
            #expect(windows.controllers.count == 1 && windows.controllers.first === launch, "the launch window closed; another window shows the workspace")
            #expect(windows.registry.value.owner(of: workspace) == launch.state.id, "the launch window does not list the workspace asked for in it")
            #expect(launch.state.workspaceID == workspace, "the launch window does not show the workspace asked for in it")
            #expect(launch.state.page == nil, "the launch window shows a top page (Home) instead of the workspace asked for")

            // The first launch's landing (`FirstWorkspaceLaunch.land`, decided before the restore placed the claim)
            // on another workspace, Home: it does not take the window from the workspace asked for at launch.
            let other = try #require(store.workspaces.first { $0.id != workspace }?.id, "the store lists no workspace but the new one")
            FirstWorkspaceLaunch(manager: windows).land(other)
            #expect(launch.state.workspaceID == workspace, "the first launch's landing replaced the workspace asked for at launch")
            result = .success(())
        } catch { result = .failure(error) }

        reaped = await owner.stop(services)
        try result.get()
    }

    private struct TimedOut: Error {}

    /// Polls until `done` holds; throws once `limit` passes.
    private static func until(_ limit: Duration, _ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !done() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
