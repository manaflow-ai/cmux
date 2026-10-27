import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A new workspace asked for while the app still connects to cmux-tui (dogfood gate v2.2.3, journey
/// `type`, failed about 1 run in 8 on v2.2.2 and v2.2.3): `newTab` ran the moment the app's socket
/// answered, the daemon made the workspace and its terminal, but the window kept showing Home with
/// "No workspaces" in its sidebar, and the keys typed next went to the Chief composer.
///
/// Until restore registers it, the launch window is outside the registry, so New Workspace's target
/// (`targetWindow(preferring:)`) was a new window id: the workspace was claimed for a second window,
/// and the launch window, which the person sees, got only Home.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct NewTabAtLaunchTests {
    /// The workspace `newTab` asks for, under the key its create sends.
    private static let created = "k-new-at-launch"
    private static let home = "k-home"

    /// The first snapshot after the create: Home (listed first, as a fresh session lists it) and the new workspace.
    private static func tree() -> DaemonTree {
        var home = WorkspaceSnapshot(id: 1, key: "k-home", name: "Home",
                                     screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [
                                         PaneSnapshot(id: 1, name: "Main", tabs: [TabSnapshot(surface: 2, title: "Chief", cwd: "/tmp")]),
                                     ])])
        home.kind = "home"
        let made = WorkspaceSnapshot(id: 2, key: "k-new-at-launch", name: "jr-type",
                                     screens: [ScreenSnapshot(id: 2, layout: .leaf(2), panes: [
                                         PaneSnapshot(id: 2, name: "Main", tabs: [TabSnapshot(surface: 1, title: "zsh", cwd: "/tmp")]),
                                     ])])
        return DaemonTree(workspaces: [home, made])
    }

    /// The app with its launch window up (the connecting state, no saved windows), New Workspace asked for
    /// there as its handler asks (`AppActions.newWorkspace`: the active window's target, claimed before the
    /// create is sent, `WorkspaceSpawner.create`), then the first snapshot listing it and the restore.
    private static func launchThenAskThenRestore() async throws -> (AppServices, WindowController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.windows.restoreWhenLoaded()
        let launch = try #require(services.windows.controllers.first)
        #expect(services.windows.launchWindowID == launch.state.id, "no launch window outside the registry: the test does not start where the bug was")

        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        services.windows.claimNew(workspaceID: created, window: target)

        services.daemon.store.apply(snapshot: tree())
        await withCheckedContinuation { continuation in services.windows.whenRestored { continuation.resume() } }
        return (services, launch)
    }

    @Test func aWorkspaceAskedForWhileConnectingShowsInTheLaunchWindow() async throws {
        let (services, launch) = try await Self.launchThenAskThenRestore()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let windows = services.windows.registry.value.windows

        #expect(windows.count == 1, "a second window took the new workspace: \(windows.map { "\($0.id): \($0.workspaceIDs)" })")
        #expect(services.windows.controllers.count == 1)
        #expect(services.windows.controllers.first === launch, "the launch window closed; another window shows the workspace")
        #expect(services.windows.registry.value.owner(of: Self.created) == launch.state.id,
                "the launch window does not list the workspace asked for in it")
        #expect(launch.state.workspaceID == Self.created, "the launch window does not show the workspace asked for in it")
        #expect(launch.state.page == nil, "the launch window shows a top page (Home) instead of the workspace asked for")
    }

    /// The first launch's landing on Home (`FirstWorkspaceLaunch`) is a default for a launch nobody asked
    /// anything of. Its decision is made before the restore places the claimed workspace (it waits for
    /// `ensure_home` and for the store to list Home), so it must not take the window back to Home from a
    /// workspace asked for during the launch. Restore calls `land` with the workspace it decided on.
    @Test func theFirstLaunchLandingOnHomeLeavesAWorkspaceAskedForAtLaunchShown() async throws {
        let (services, launch) = try await Self.launchThenAskThenRestore()
        defer { for controller in services.windows.controllers { controller.window?.close() } }

        FirstWorkspaceLaunch(manager: services.windows).land(Self.home)

        #expect(launch.state.workspaceID == Self.created, "the landing on Home replaced the workspace asked for at launch")
        #expect(launch.state.page == nil, "the landing on Home replaced the workspace asked for at launch")
    }

    /// With saved windows and no launch snapshot, the launch window opens under a new id and restore gives
    /// it the frontmost saved window's id (`adoptLaunchWindow`). A workspace claimed for it meanwhile goes
    /// with it: a claim left on the old id would open a second window under that id. A reconcile before
    /// the restore keeps the claim: the restore replaces the registry it would have written.
    @Test func aClaimOnTheLaunchWindowWaitsForTheRestoreAndFollowsItsAdoptedIdentity() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let launch = try #require(services.windows.launchWindowID)
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        #expect(target == launch, "New Workspace while connecting targets a second window, not the launch window")
        services.windows.claimNew(workspaceID: Self.created, window: target, frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        // Cmd-N's New Tab page releases its first-tab hold with a reconcile, which can come before the restore.
        services.daemon.store.apply(snapshot: Self.tree())
        services.windows.reconcileMembership()
        #expect(services.windows.registry.value.owner(of: Self.created) == nil, "a reconcile before the restore placed the launch window's claim")
        #expect(services.windows.pendingClaims[Self.created] == launch, "a reconcile before the restore dropped the launch window's claim")

        services.windows.launchWindowAdopted(from: launch, as: "saved-front")

        #expect(services.windows.pendingClaims[Self.created] == "saved-front")
        #expect(services.windows.pendingFrames[launch] == nil && services.windows.pendingFrames["saved-front"] != nil)
    }

    /// Home only: the store before the asked-for workspace is created.
    private static func homeOnly() -> DaemonTree {
        DaemonTree(workspaces: [tree().workspaces[0]])
    }

    /// The real create runs a reconcile before it sends the create command (`FirstTabHold.creating` releases at
    /// once for a terminal), with Home already listed: that reconcile registers the launch window early. The
    /// workspace's own delta came next and its reconcile placed the claim in the registry the restore then
    /// replaces with the saved one (a relaunch with saved windows lost it to another window, unselected).
    /// The claim stays pending until the restore's own reconcile places it.
    @Test func aClaimOnTheLaunchWindowSurvivesTheReconcilesBeforeTheRestore() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let launch = try #require(services.windows.controllers.first)
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        services.windows.claimNew(workspaceID: Self.created, window: target)

        // In one main-actor turn, before the restore task runs: the release's reconcile, then the workspace's delta.
        services.daemon.store.apply(snapshot: Self.homeOnly())
        services.windows.reconcileMembership()
        services.daemon.store.apply(snapshot: Self.tree())
        services.windows.reconcileMembership()
        #expect(services.windows.registry.value.owner(of: Self.created) == nil,
                "a reconcile before the restore placed the launch window's claim in the registry the restore replaces")
        #expect(services.windows.pendingClaims[Self.created] == launch.state.id, "a reconcile before the restore dropped the claim")

        await withCheckedContinuation { continuation in services.windows.whenRestored { continuation.resume() } }
        #expect(services.windows.registry.value.windows.count == 1)
        #expect(services.windows.registry.value.owner(of: Self.created) == launch.state.id)
        #expect(launch.state.workspaceID == Self.created, "the launch window does not show the workspace asked for in it")
    }

    /// A script's create without `focus` (no view change) during the launch files the workspace into the
    /// launch window without showing it, as it does for any open window: it neither selects it there nor
    /// sends the launch window, the one the person looks at, behind the others.
    @Test func aQuietCreateAtLaunchFilesItsWorkspaceWithoutShowingItOrSendingTheWindowBehind() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let launch = try #require(services.windows.controllers.first)
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            services.windows.claimNew(workspaceID: Self.created, window: target)
        }
        #expect(!services.windows.behindWindows.contains(launch.state.id), "a quiet create sends the launch window behind")
        #expect(services.windows.quietClaims.contains(Self.created), "a quiet create at launch would be shown on arrival")

        services.daemon.store.apply(snapshot: Self.tree())
        await withCheckedContinuation { continuation in services.windows.whenRestored { continuation.resume() } }
        #expect(services.windows.registry.value.owner(of: Self.created) == launch.state.id, "the quiet workspace is not in the launch window")
        #expect(launch.state.workspaceID != Self.created, "a quiet create at launch took the launch window")
    }

    /// While the launch shows its saved window's picture, that window has no controller yet, so no window is
    /// active: New Workspace's target was a new window, beside the launch window. The window the launch stands
    /// for is the target (`activeWindowID`).
    @Test func beforeTheLaunchWindowHasAControllerNewWorkspaceTargetsIt() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.windows.launchWindowID = "picture-front"
        #expect(services.windows.active == nil)
        #expect(services.windows.targetWindow(preferring: services.windows.activeWindowID) == "picture-front")
    }
}
