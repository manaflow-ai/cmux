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

/// The Chief window dock (user 2026-11-05: "when i click it from chief, it will bring me to workspace, but with the
/// chief still on the left … the chief UI part does not change at all, so if i have typed stuff, the typed stuff
/// is still there, if i have scrolled in chief ui, im still scrolled there"), and the window dock it is one of: any
/// pane moves in, the Home Chief pane's no-tab-bar mode per dock, and its Cmd-Shift-P actions.
///
/// A real window with four workspaces `k0`...`k3`; `k0` plays Home (one pane, one tab: the Chief's), and holds a
/// draft (a text view with a selection) and a scrolled view, as the Chief's message box and transcript do.
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

    // MARK: - A link from the Chief

    /// A link clicked in the Chief shows its workspace on the stage with the Chief docked left: the same view, its
    /// draft, selection and scroll kept. Then switching the stage (sidebar picks) never touches the dock's view: not
    /// hidden, not moved, not re-mapped.
    @Test func aLinkFromTheChiefDocksItAndStageSwitchesNeverTouchItsView() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            let chief = try #require(f.controller.content)
            try #require(chief.workspace.id == "k0")
            let view = chief.contentView
            let state = ChiefState(in: view)

            f.controller.armChiefDock(home: "k0", edge: .left)
            f.services.windows.show(workspaceID: "k1", in: f.state) // the link's jump
            f.frame()
            #expect(f.state.docks.dock(at: .left)?.workspace == "k0", "the Chief did not dock left")
            #expect(f.state.workspaceID == "k1" && f.shown == ["k0", "k1"], "shown \(f.shown)")
            let left = try #require(f.windowFrame("k0")), right = try #require(f.windowFrame("k1"))
            #expect(left.maxX <= right.minX, "the Chief is not on the left: \(left) \(right)")
            #expect(f.controller.parked["k0"] === chief, "the Chief's content was replaced")
            #expect(chief.contentView === view)
            state.expectKept(in: view, "after the link")

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
            #expect(chief.panes.values.map(\.debugSnapshotRuns) == runs, "a stage switch re-mapped the docked Chief's panes")
            #expect(f.state.docks.all.map(\.workspace) == ["k0"], "the sidebar picks changed the dock")
        }
    }

    /// Without a link from the Chief, a sidebar pick replaces Home as before: nothing docks.
    @Test func aSidebarPickFromHomeDocksNothing() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
            f.frame()
            #expect(f.state.docks.isEmpty)
            #expect(f.shown == ["k1"])
        }
    }

    /// A link that showed nothing in time (refused, or opened in another window) leaves the arm to lapse: a later
    /// sidebar pick does not dock Home.
    @Test func aLapsedArmDocksNothing() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            f.controller.armChiefDock(home: "k0", edge: .left, now: ContinuousClock.now - .seconds(60))
            f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
            f.frame()
            #expect(f.state.docks.isEmpty)
            #expect(f.controller.chiefDockOnLeave == nil, "the show did not take the arm")
        }
    }

    /// `home.chiefDock.edge` bottom: the Chief docks under the stage.
    @Test func theChiefDocksAtTheSettingsEdge() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            f.controller.armChiefDock(home: "k0", edge: .bottom)
            f.services.windows.show(workspaceID: "k2", in: f.state)
            f.frame()
            #expect(f.state.docks.dock(at: .bottom)?.workspace == "k0")
            let top = try #require(f.windowFrame("k2")), bottom = try #require(f.windowFrame("k0"))
            #expect(bottom.maxY <= top.minY, "the Chief is not under the stage: \(top) \(bottom)") // window y runs up
        }
    }

    // MARK: - Undock Chief (cmux#37372)

    /// Undock Chief, run from the docked Chief (its pane's menu or the palette): Home leaves the dock and the
    /// window shows the stage's workspace alone, with the keys; a second run has nothing to undock.
    @Test func undockChiefLeavesTheStageAndGivesItTheKeys() async throws {
        try await Self.withDocks {
            let f = try await Fixture(keys: Self.keys, tree: Self.tree())
            defer { f.close() }
            f.controller.armChiefDock(home: "k0", edge: .left)
            f.services.windows.show(workspaceID: "k1", in: f.state) // a link from the Chief
            f.frame()
            f.controller.openChiefDock("k0", edge: .left) // the Chief has the keys
            f.frame()
            try #require(f.state.docks.isDocked("k0") && f.state.workspaceID == "k0" && f.state.stageWorkspaceID == "k1")

            #expect(f.controller.undockChief("k0"))
            f.frame()
            #expect(f.state.docks.isEmpty, "the Chief is still docked: \(f.state.docks.all.map(\.workspace))")
            #expect(f.state.workspaceID == "k1" && f.shown == ["k1"], "the stage did not keep the window: shown \(f.shown)")
            #expect(!f.controller.undockChief("k0"), "a second Undock Chief undocked something")
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
            f.controller.openChiefDock("k0", edge: .left)
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
            f.controller.openChiefDock("k0", edge: .left)
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
            f.controller.openChiefDock("k0", edge: .left)
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
