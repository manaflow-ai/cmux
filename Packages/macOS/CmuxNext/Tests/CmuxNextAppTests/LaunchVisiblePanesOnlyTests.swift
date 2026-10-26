import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFeatures
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Hidden workspaces and panes stay model-only at launch (p08-startup-065, `launchVisiblePanesOnly`):
/// a window of 60 workspaces builds the one it shows and nothing of the other 59; until startup
/// completes a pane the layout does not report on screen makes no content, one on screen does
/// (counted in `views_built`), one in the keep-alive band makes its content after completion, and
/// one away stays model-only until the layout brings it near.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchVisiblePanesOnlyTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "launch-visible-panes-test")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// The app at launch with the feature on: its presentation and the launch's posts run on the same hand-run frames.
    @MainActor final class Launch {
        let scheduler = StartupTestScheduler()
        let services: AppServices

        init() throws {
            _ = NSApplication.shared
            let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                       overrides: FeatureOverrides(environmentEnabled: [Feature.launchVisiblePanesOnly.name]))
            services = AppServices(environment: AppEnvironment.current([:]), mainWork: scheduler.mainWork,
                                   launchStartup: scheduler.startup, features: features)
            services.windows.ordersWindowsIn = false
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            services.daemon.store.noteHandshake(identity)
            services.daemon.store.connectionState = .connected(identity)
        }

        func frames(_ count: Int = 6) {
            for _ in 0..<count { scheduler.fire() }
        }

        func tearDown() {
            scheduler.startup.beginQuit()
            for controller in services.windows.controllers { controller.window?.close() }
        }
    }

    /// `count` workspaces of one terminal pane each, in sidebar order.
    private static func tree(workspaces count: Int) -> DaemonTree {
        let workspaces = (1...count).map { index -> WorkspaceSnapshot in
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(index)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(index)), title: "~")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(index)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index)), key: WorkspaceKey(rawValue: "ws\(index)"), name: "ws\(index)", screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: workspaces)
        tree.personal = PersonalState(workspaces: (1...count).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ws\($0)"), index: $0 - 1)
        })
        return tree
    }

    /// One pane outside a workspace with one page tab selected, as a restored pane before the layout
    /// reports where it is. The pane holds its window state weakly: the caller keeps it.
    private static func pane(in launch: Launch) throws -> (WindowState, PaneController, key: String) {
        let store = launch.services.daemon.store
        store.apply(snapshot: tree(workspaces: 1))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"ws1"}"#.utf8))
        let provider = Provider()
        launch.services.pages.register(provider)
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: launch.services.daemon, layoutPaneID: LayoutPaneID(model.id),
                                  services: launch.services, state: state)
        let key = launch.services.pages.open(provider.page, in: pane.paneKey, of: store)
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(key))
        return (state, pane, key)
    }

    /// Acceptance: 60 workspaces in one window build 1: no controller, pane or terminal for the 59 hidden ones.
    @Test func aWindowOfSixtyWorkspacesBuildsOnlyTheOneItShows() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.services.daemon.store.apply(snapshot: Self.tree(workspaces: 60))
        let keys = (1...60).map { "ws\($0)" }
        let controller = try #require(launch.services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let shown = try #require(controller.workspaceContent)
        shown.contentView.layoutSubtreeIfNeeded()
        launch.frames()
        #expect(launch.services.windows.controllers.count == 1)
        #expect(keys.contains(shown.workspace.id))
        #expect(controller.parked.isEmpty, "hidden workspaces built controllers: \(controller.parked.keys.sorted())")
        #expect(shown.panes.count <= 1, "panes of another workspace mounted: \(shown.panes.count)")
        #expect(launch.services.cache.liveTerminalCount <= 1, "hidden workspaces attached terminals: \(launch.services.cache.liveTerminalCount)")
        #expect(launch.services.launchPanes.viewsBuilt <= 1)
    }

    /// A pane the layout has not reported on screen makes no content at launch, and spends no frame's surface creation.
    @Test func aPaneNotOnScreenMakesNoContentAtLaunch() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        launch.frames()
        #expect(launch.services.pages.existingView(key) == nil, "a pane off screen made its page before startup completed")
        #expect(pane.waitsForLaunchEnd)
        #expect(pane.selectedContentIsAlive, "a held pane counts as cheap to show, so it takes no frame's creation")
        #expect(launch.services.launchPanes.viewsBuilt == 0)
    }

    /// The layout reports the pane on screen: it makes its content before completion, counted as a view built;
    /// not the workspace's focused pane, it waits for the next frame instead of showing in the report's turn.
    @Test func aPaneOnScreenMakesItsContentAndCountsAsBuilt() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        pane.setPresence(.visible)
        #expect(launch.services.pages.existingView(key) == nil, "a pane that is not the focused one showed in the report's turn")
        launch.frames()
        #expect(launch.services.pages.existingView(key) != nil, "a pane on screen made no content")
        #expect(launch.scheduler.startup.completion == nil)
        #expect(launch.services.launchPanes.viewsBuilt == 1)
    }

    /// A pane in the keep-alive band makes its content right after startup completes, not before.
    @Test func aPaneInTheKeepAliveBandMakesItsContentAfterCompletion() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        pane.setPresence(.keepAlive)
        launch.frames()
        #expect(launch.services.pages.existingView(key) == nil, "a pane in the keep-alive band built before completion")
        launch.scheduler.complete()
        launch.frames(10)
        #expect(launch.services.pages.existingView(key) != nil, "the keep-alive pane never made its content after completion")
        #expect(!pane.waitsForLaunchEnd)
        #expect(launch.services.launchPanes.viewsBuilt == 0, "a view built after completion counted")
    }

    /// A pane away from the viewport stays model-only after completion, until the layout brings it near.
    @Test func aPaneAwayStaysModelOnlyUntilItComesNear() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        launch.scheduler.complete()
        launch.frames(10)
        #expect(launch.services.pages.existingView(key) == nil, "a pane away made its content after completion")
        pane.setPresence(.visible)
        launch.frames()
        #expect(launch.services.pages.existingView(key) != nil, "the pane made no content once on screen")
    }
}
