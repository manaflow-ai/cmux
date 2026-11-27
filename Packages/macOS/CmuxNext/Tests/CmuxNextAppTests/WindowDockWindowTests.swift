import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// The window dock (user 2026-11-05): a docked workspace keeps its view across stage switches, any pane moves in,
/// the Home Chief pane's no-tab-bar mode per dock, and its Cmd-Shift-P actions. The Chief itself docks as the Chief
/// panel instead (user 2026-11-06, `ChiefPanelWindowTests`).
///
/// A real window with four workspaces `k0`...`k3`; `k0` has one pane with one tab, and holds a draft (a text view
/// with a selection) and a scrolled view.
@MainActor @Suite(.serialized, .closesItsWindows)
struct WindowDockWindowTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture
    static let keys = ["k0", "k1", "k2", "k3"]

    /// `k0` holds one tab (the Chief's pane); the others a terminal and a page.
    static func tree() -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            let screen: ScreenSnapshot
            if key == "k0" {
                let pane = PaneSnapshot(id: PaneID(rawValue: 900), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 901), title: "Chief")])
                screen = ScreenSnapshot(id: ScreenID(rawValue: 900), layout: .leaf(pane.id), panes: [pane])
            } else {
                screen = SpaceSwitchBench.screen(index)
            }
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    /// Window docks on (their default), put back as found.
    static func withDocks<T>(_ body: () async throws -> T) async rethrows -> T {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register([LayoutTunables.dockedWorkspaces.descriptor])
        let key = LayoutTunables.dockedWorkspaces.key, before = store.override(key)
        store.set(key, .bool(true))
        defer { store.set(key, before) }
        return try await body()
    }

    /// The Chief's UI state inside its view: a draft with a selection, and a scrolled transcript.
    @MainActor final class ChiefState {
        let draft = NSTextView(frame: NSRect(x: 8, y: 8, width: 220, height: 40))
        let transcript = NSScrollView(frame: NSRect(x: 8, y: 60, width: 220, height: 120))

        init(in view: NSView) {
            draft.string = "half-typed reply to the Chief"
            draft.setSelectedRange(NSRange(location: 5, length: 5))
            transcript.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 4000))
            transcript.contentView.scroll(to: NSPoint(x: 0, y: 1700))
            transcript.reflectScrolledClipView(transcript.contentView)
            view.addSubview(draft)
            view.addSubview(transcript)
        }

        func expectKept(in view: NSView, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(draft.string == "half-typed reply to the Chief", "\(step): the draft changed", sourceLocation: sourceLocation)
            #expect(draft.selectedRange() == NSRange(location: 5, length: 5), "\(step): the selection moved", sourceLocation: sourceLocation)
            #expect(transcript.contentView.bounds.origin.y == 1700, "\(step): the scroll position moved", sourceLocation: sourceLocation)
            #expect(draft.superview === view && transcript.superview === view, "\(step): the Chief's view was rebuilt", sourceLocation: sourceLocation)
        }
    }

    // MARK: - A docked workspace

    /// A docked workspace keeps its view while the stage switches (sidebar picks): the same view, its draft,
    /// selection and scroll kept, not hidden, not moved, not re-mapped. (Home never docks as a workspace: its Chief
    /// docks as the Chief panel, `ChiefPanelWindowTests`.)
    @Test func aDockedWorkspaceKeepsItsViewAcrossStageSwitches() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            let chief = try #require(f.controller.content)
            try #require(chief.workspace.id == "k0")
            let view = chief.contentView
            let state = ChiefState(in: view)

            f.controller.dockWorkspace("k0", at: .left)
            f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
            f.frame()
            #expect(f.state.docks.dock(at: .left)?.workspace == "k0", "k0 did not dock left")
            #expect(f.state.workspaceID == "k1" && f.shown == ["k0", "k1"], "shown \(f.shown)")
            let left = try #require(f.windowFrame("k0")), right = try #require(f.windowFrame("k1"))
            #expect(left.maxX <= right.minX, "the dock is not on the left: \(left) \(right)")
            #expect(f.controller.parked["k0"] === chief, "the docked content was replaced")
            #expect(chief.contentView === view)
            state.expectKept(in: view, "after the dock")

            let dockFrame = view.frame
            let runs = chief.panes.values.map(\.debugSnapshotRuns)
            for id in ["k2", "k3", "k1"] {
                f.services.windows.show(workspaceID: id, in: f.state, from: .thisWindow) // a sidebar pick
                f.frame()
                #expect(f.state.workspaceID == id && f.shown == ["k0", id], "after \(id): shown \(f.shown)")
                #expect(!view.isHiddenOrHasHiddenAncestor && view.superview === f.controller.root.contentHost, "after \(id): the dock left the screen")
                #expect(view.frame == dockFrame, "after \(id): the dock moved")
                state.expectKept(in: view, "after \(id)")
            }
            #expect(chief.panes.values.map(\.debugSnapshotRuns) == runs, "a stage switch re-mapped the docked panes")
            #expect(f.state.docks.all.map(\.workspace) == ["k0"], "the sidebar picks changed the dock")
        }
    }

    /// A sidebar pick replaces the shown workspace as before: nothing docks.
    @Test func aSidebarPickDocksNothing() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
            f.frame()
            #expect(f.state.docks.isEmpty)
            #expect(f.shown == ["k1"])
        }
    }

    // MARK: - A relaunch (cmux#37365)

    /// `tree()` with `k0` as the store's Home (`kind` "home"), as the frame reads it.
    static func homeTree() -> DaemonTree {
        var tree = tree()
        tree.workspaces[0].kind = "home"
        return tree
    }

    /// A Chief an older build docked (by a link, or by Cmd-I) comes back undocked after a relaunch: Home never docks
    /// (user 2026-11-06), and the window shows no Chief until the person asks. A dock the person made of another
    /// workspace stays.
    @Test(arguments: [false, true]) func aRelaunchShowsNoChiefAnOlderBuildDocked(byLink: Bool) async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.homeTree())
            f.services.windows.show(workspaceID: "k1", in: f.state)
            f.frame()
            f.controller.dockWorkspace("k2", at: .bottom) // Dock Workspace Bottom: the person's choice
            f.frame()
            try #require(f.state.docks.dock(at: .bottom)?.workspace == "k2")
            let record = try #require(f.services.windows.registry.value.record(f.state.id, state: f.state, order: 0))
            var json = try #require(String(data: try JSONEncoder().encode(record), encoding: .utf8))
            // An older build's record: Home docked at the left beside k2's dock.
            let home = #"{"edge":"left","workspace_key":"k0","mode":"docked","extent_permille":300,"hidden":false"# +
                (byLink ? #","by_link":true}"# : "}")
            json = json.replacingOccurrences(of: #""docks":["#, with: #""docks":["# + home + ",")
            try #require(json.contains(#""workspace_key":"k0""#), "the test did not write the old dock: \(json)")
            f.close()

            let again = try await Fixture(keys: Self.keys, record: json, tree: Self.homeTree())
            defer { again.close() }
            again.frame()
            #expect(!again.state.docks.isDocked("k0"), "the relaunch kept the Chief docked: \(again.state.docks.all.map(\.workspace))")
            #expect(!again.controller.frameChiefPanelShown, "the relaunch showed the Chief")
            #expect(again.state.docks.dock(at: .bottom)?.workspace == "k2", "the relaunch dropped a dock the person made")
        }
    }

    // MARK: - Cmd-Shift-P actions

    /// Show/Hide Dock Tab Bar gives the dock the Home Chief pane's mode (one tab: no bar), per dock; Move Dock to
    /// Right moves it; Show/Hide Dock hides and shows it; Focus Dock focuses its workspace. Each runs through the
    /// registry, the path of the palette, the keyboard, the CLI and MCP.
    @Test func thePaletteActionsDriveTheDock() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            AppActions.bind(f.services)
            let registry = f.services.registry
            @MainActor func run(_ id: ActionID) -> Bool { registry.perform(id, invocation: ActionInvocation(origin: .user)) }
            f.controller.dockWorkspace("k0", at: .left)
            f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
            f.frame()
            try #require(f.state.docks.dock(at: .left)?.workspace == "k0" && f.shown == ["k0", "k1"], "shown \(f.shown)")
            let chiefPane = try #require(f.controller.parked["k0"]?.panes.values.first)
            let stagePane = try #require(f.controller.content?.panes.values.first)
            #expect(!chiefPane.structure().hidesStrip, "the dock's tab bar shows by default")

            #expect(run("window.toggleDockTabBar"))
            #expect(f.state.docks.dock(at: .left)?.hidesTabBar == true)
            #expect(chiefPane.structure().hidesStrip, "one tab in a no-tab-bar dock: no tab bar")
            #expect(!stagePane.structure().hidesStrip, "the stage keeps its tab bar")

            #expect(run("window.dockEdgeRight"))
            f.frame()
            #expect(f.state.docks.dock(at: .right)?.workspace == "k0" && f.state.docks.dock(at: .left) == nil)
            let stage = try #require(f.windowFrame("k1")), dock = try #require(f.windowFrame("k0"))
            #expect(stage.maxX <= dock.minX, "the dock is not on the right: \(stage) \(dock)")
            #expect(f.state.docks.dock(at: .right)?.hidesTabBar == true, "the move kept the tab-bar mode")

            #expect(run("window.toggleDock"))
            f.frame()
            #expect(f.shown == ["k1"], "Show/Hide Dock did not hide it: \(f.shown)")
            #expect(run("window.toggleDock"))
            f.frame()
            #expect(f.shown == ["k0", "k1"])

            #expect(run("window.focusDock"))
            f.frame()
            #expect(f.state.workspaceID == "k0", "Focus Dock did not focus the dock's workspace")
            #expect(f.shown == ["k0", "k1"], "focusing the dock moved it to the stage")
        }
    }

    /// With no dock, the dock actions refuse with a reason instead of doing nothing.
    @Test func theDockActionsRefuseWithNoDock() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            AppActions.bind(f.services)
            for id in ["window.toggleDock", "window.toggleDockTabBar", "window.focusDock", "window.dockEdgeTop"] as [ActionID] {
                let reason = f.services.registry.capturingRefusal {
                    _ = f.services.registry.perform(id, invocation: ActionInvocation(origin: .user))
                }
                #expect(reason == RefusalStrings.windowHasNoDock, "\(id): \(reason ?? "ran")")
            }
        }
    }

    // MARK: - Panes in and out

    /// Move Pane to Dock: a stage pane's tabs go into the dock's workspace; a pane in the dock is refused.
    @Test func movePaneToDockMovesItsTabsIntoTheDock() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            AppActions.bind(f.services)
            f.controller.dockWorkspace("k0", at: .left)
            f.services.windows.show(workspaceID: "k2", in: f.state, from: .thisWindow)
            f.frame()
            let moving = f.tabs("k2")
            try #require(!moving.isEmpty)
            let pane = try #require(f.services.workspace(id: "k2")?.screens.first?.panes.first)
            @MainActor func moveToDock(_ pane: PaneModel) -> String? {
                f.services.registry.capturingRefusal {
                    _ = f.services.registry.perform("window.movePaneToDock",
                                                    invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id)))
                }
            }
            // The fixture has no daemon connection, so no move echoes: the run shows one move-tab-to-workspace per
            // tab of the pane, each the daemon's work the run tracks (and each fails here for want of a daemon).
            var refused: String?
            let work = f.services.registry.capturingWork { refused = moveToDock(pane) }
            #expect(refused == nil, "refused: \(refused ?? "-")")
            #expect(work.count == moving.count, "\(work.count) moves for \(moving.count) tabs")
            for task in work {
                let failure = await task.value
                #expect(failure?.message.contains("move-tab-to-workspace") == true, "not a tab move: \(String(describing: failure))")
            }

            let docked = try #require(f.services.workspace(id: "k0")?.screens.first?.panes.first)
            #expect(moveToDock(docked) == RefusalStrings.paneAlreadyInDock)
        }
    }

    /// A pane or tab dragged over the dock drops into the docked workspace, as onto any workspace on screen
    /// (`content(atScreen:)`, the drag's drop resolver), and one dragged over the stage into the stage's: the dock
    /// is a drop target both ways, so panes drag in and back out.
    @Test func aDropOverTheDockGoesToTheDockedWorkspace() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            f.controller.dockWorkspace("k0", at: .left)
            f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
            f.frame()
            let dockView = try #require(f.controller.parked["k0"]?.contentView)
            let window = try #require(f.controller.window)
            let inDock = dockView.convert(NSPoint(x: dockView.bounds.midX, y: dockView.bounds.midY), to: nil)
            #expect(f.controller.content(atScreen: window.convertPoint(toScreen: inDock))?.workspace.id == "k0",
                    "a drop over the dock does not resolve to the docked workspace")
            let onStage = try #require(f.windowFrame("k1"))
            #expect(f.controller.content(atScreen: window.convertPoint(toScreen: NSPoint(x: onStage.midX, y: onStage.midY)))?.workspace.id == "k1")
        }
    }
}
