import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// The Chief panel (user 2026-11-06): "it should only be a special state that only happens if i click the open
/// workspace indicator … if i click the workspace explicitly, the chief should not show up on the left … a
/// modal/popover codepath … though we should support concept of docking"; "docked Chief is a separate mode that
/// never appears in Home … only Chief by default, with no extra splits"; "must not bring Home's right side along";
/// "Cmd+Ctrl+H/J/K/L, Cmd+Option+arrow keys … must go into and out of the docked Chief like any pane"; "Cmd+I must
/// also hide the docked Chief"; "maybe we should have windowed chief instead, where chief floats in the window".
///
/// A real window with four workspaces: `k0` is Home (the tree marks it `home`), `k1`...`k3` ordinary ones. The
/// panel holds a stand-in for the Chief's view with a draft (a text view with a selection) and a scrolled
/// transcript, as the Chief's message box and transcript do.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChiefPanelWindowTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture
    typealias ChiefState = WindowDockWindowTests.ChiefState
    static let keys = ["k0", "k1", "k2", "k3"]

    /// `k0` is Home: one pane, one tab (the Chief's). `k1` has two panes side by side; the others one each.
    static func tree() -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            let screen: ScreenSnapshot
            switch key {
            case "k0":
                let pane = PaneSnapshot(id: PaneID(rawValue: 900), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 901), title: "Chief")])
                screen = ScreenSnapshot(id: ScreenID(rawValue: 900), layout: .leaf(pane.id), panes: [pane])
            case "k1": screen = Fixture.twoPanes(unread: false)
            default: screen = SpaceSwitchBench.screen(index)
            }
            var workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
            if key == "k0" { workspace.kind = "home" }
            return workspace
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    /// A window showing Home, its panel holding `chief` (the Chief's view stand-in).
    static func fixture(_ chief: NSView) async throws -> Fixture {
        let f = try await Fixture(keys: keys, tree: tree())
        f.controller.chiefPanelSource = { chief }
        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
        f.frame()
        try #require(f.controller.content?.workspace.id == "k0" && f.controller.frameHome == "k0", "the window does not show Home")
        return f
    }

    /// Whether two frames match to a point (a place kept as a share of the window rounds to whole points).
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    static func chiefView() -> (NSView, ChiefState) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        return (view, ChiefState(in: view))
    }

    /// The panel's frame in the content host, when it draws.
    static func panelFrame(_ f: Fixture) -> CGRect? {
        guard f.controller.frameChiefPanelShown, let view = f.controller.chiefPanelView else { return nil }
        return view.frame
    }

    /// Clicking the open-workspace indicator (a link in the Chief) opens its workspace with the Chief floating over
    /// it: the workspace fills the content area under it (its layout untouched, no dock), and the panel holds the
    /// Chief's own view, its draft, selection and scroll kept.
    @Test func theIndicatorOpensTheWorkspaceWithTheChiefFloatingOverIt() async throws {
        let (chief, state) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state) // the link's jump
        f.frame()
        #expect(f.controller.frameChiefPanelShown, "the Chief did not open over the workspace")
        #expect(f.state.chiefPanel.dockedEdge == nil, "the Chief docked instead of floating")
        #expect(f.state.docks.isEmpty, "the link docked a workspace")
        #expect(f.shown == ["k1"], "shown \(f.shown): Home stayed on screen")
        let host = f.controller.root.contentHost.bounds
        #expect(f.controller.content?.contentView.frame == host, "the workspace does not fill the content area under the Chief")
        let panelView = try #require(f.controller.chiefPanelView)
        #expect(panelView.window === panelView.launcher && panelView.launcher?.isVisible == true, "the Chief does not float in its own window")
        #expect(f.controller.chiefPanelView?.chief === chief, "the panel does not hold the Chief's view")
        #expect(chief.isDescendant(of: try #require(f.controller.chiefPanelView)))
        state.expectKept(in: chief, "after the link")
    }

    /// A workspace opened any other way (the sidebar, a switch, a link whose arm lapsed) shows no Chief, floating or
    /// docked.
    @Test func aWorkspaceOpenedAnyOtherWayShowsNoChief() async throws {
        let (chief, _) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        for id in ["k1", "k2", "k0", "k3"] {
            f.services.windows.show(workspaceID: id, in: f.state, from: .thisWindow) // a sidebar pick
            f.frame()
            #expect(!f.controller.frameChiefPanelShown, "\(id): the Chief showed")
            #expect(f.state.docks.isEmpty, "\(id): a workspace docked")
            #expect(f.shown == [id], "\(id): shown \(f.shown)")
        }
        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
        f.controller.armChiefPanel(now: ContinuousClock.now - .seconds(60)) // a link that never showed its workspace
        f.services.windows.show(workspaceID: "k2", in: f.state, from: .thisWindow)
        f.frame()
        #expect(!f.controller.frameChiefPanelShown, "a lapsed arm opened the Chief")
        #expect(f.controller.frameChiefPanelArm == nil, "the show did not take the arm")
    }

    /// The Chief never shows over Home, floating or docked: Home fills the window with its Chief in its own pane,
    /// and the next other workspace gets the panel back the way it was.
    @Test func theChiefNeverShowsOverHome() async throws {
        let (chief, state) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        try #require(f.controller.frameChiefPanelShown)
        for docked in [false, true] {
            if docked { f.controller.dockChiefPanel(at: .left) }
            f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
            f.frame()
            #expect(!f.controller.frameChiefPanelShown, "docked \(docked): the Chief showed over Home")
            #expect(f.shown == ["k0"], "docked \(docked): Home does not fill the window: \(f.shown)")
            #expect(f.controller.chiefPanelView?.chief == nil, "docked \(docked): the panel kept the Chief's view in Home")
            f.services.windows.show(workspaceID: "k2", in: f.state, from: .thisWindow)
            f.frame()
            #expect(f.controller.frameChiefPanelShown, "docked \(docked): the open panel did not come back after Home")
            #expect((f.state.chiefPanel.dockedEdge != nil) == docked)
            state.expectKept(in: chief, "docked \(docked), back from Home")
        }
    }

    /// Docked, the panel is the Chief chat alone at its edge: no Home workspace on screen (none of Home's other
    /// panes), no extra split, the stage beside it. Float floats it again over the whole stage.
    @Test func dockedTheChiefIsOnlyTheChiefChatBesideTheStage() async throws {
        let (chief, state) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        let runs = f.controller.content?.panes.values.map(\.debugSnapshotRuns)
        f.controller.dockChiefPanel(at: .left)
        f.frame()
        #expect(f.state.chiefPanel.dockedEdge == .left)
        #expect(f.shown == ["k1"], "Home's workspace (its other panes) came on screen: \(f.shown)")
        #expect(f.state.docks.isEmpty, "docking the Chief docked a workspace")
        let panel = try #require(Self.panelFrame(f)), stage = try #require(f.controller.content?.contentView.frame)
        #expect(panel.maxX <= stage.minX, "the Chief is not left of the stage: \(panel) \(stage)")
        #expect(panel.height == f.controller.root.contentHost.bounds.height, "the docked Chief does not run the full height")
        let body = try #require(chief.superview)
        #expect(body.subviews == [chief], "the docked Chief holds more than the Chief chat")
        #expect(f.controller.content?.panes.values.map(\.debugSnapshotRuns) == runs, "docking re-mapped the stage's panes")
        state.expectKept(in: chief, "docked")

        #expect(f.controller.floatChiefPanel())
        f.frame()
        #expect(f.state.chiefPanel.dockedEdge == nil)
        #expect(f.controller.content?.contentView.frame == f.controller.root.contentHost.bounds, "the stage did not take the area back")
        #expect(f.controller.frameChiefPanelShown)
    }

    /// Dock Workspace Left on Home docks the Chief panel (a Chief-only pane), never Home as a workspace; Undock
    /// floats it.
    @Test func dockWorkspaceOnHomeDocksTheChiefNotHome() async throws {
        try await WindowDockWindowTests.withDocks { try await dockWorkspaceOnHome() }
    }

    private func dockWorkspaceOnHome() async throws {
        let (chief, _) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        AppActions.bind(f.services)
        #expect(f.services.registry.perform("workspace.dockLeft", invocation: ActionInvocation(origin: .user)))
        f.frame()
        #expect(f.state.docks.isEmpty, "Home docked as a workspace")
        #expect(f.state.chiefPanel.dockedEdge == .left)
        #expect(f.shown == ["k0"] && !f.controller.frameChiefPanelShown, "the Chief docked over Home")
        f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
        f.frame()
        #expect(f.controller.frameChiefPanelShown && f.shown == ["k1"])
        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
        #expect(f.services.registry.perform("workspace.undock", invocation: ActionInvocation(origin: .user)))
        #expect(f.state.chiefPanel.dockedEdge == nil)
    }

    /// Cmd-I (Show/Hide Chief) hides the panel when it shows, docked or floating, and shows it again with the keys.
    @Test func cmdIHidesTheChiefAndShowsItAgain() async throws {
        let (chief, state) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        AppActions.bind(f.services)
        @MainActor func cmdI() -> Bool { f.services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)) }
        let cmdIKey = try #require(f.services.registry.descriptors.first { $0.id == "home.openChiefDock" }?.defaultShortcut)
        #expect(cmdIKey == Shortcut("i", modifiers: [.command]))
        f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
        f.frame()
        try #require(!f.controller.frameChiefPanelShown)
        for docked in [false, true] {
            if docked {
                f.controller.dockChiefPanel(at: .left) // docking opens it: hide it first, Cmd-I shows it
                f.controller.hideChiefPanel()
            }
            #expect(cmdI())
            f.frame()
            #expect(f.controller.frameChiefPanelShown, "docked \(docked): Cmd-I did not show the Chief")
            #expect(f.controller.frameChiefPanelHasKeys, "docked \(docked): Cmd-I did not give the Chief the keys")
            #expect(cmdI())
            f.frame()
            #expect(!f.controller.frameChiefPanelShown, "docked \(docked): Cmd-I did not hide the Chief")
            #expect(f.shown == ["k1"] && f.controller.content?.contentView.frame == f.controller.root.contentHost.bounds,
                    "docked \(docked): the stage did not take the area back")
            #expect((f.state.chiefPanel.dockedEdge != nil) == docked, "docked \(docked): hiding lost the placement")
        }
        state.expectKept(in: chief, "after Cmd-I")
    }

    /// Pane focus moves (Cmd-Ctrl-H/J/K/L, Cmd-Option-arrows: the focusLeft/Right/Up/Down actions) go into the
    /// docked Chief off the stage's edge and back out of it, as between any panes; the floating Chief takes a move
    /// toward its side.
    @Test func paneFocusMovesGoIntoAndOutOfTheChief() async throws {
        let (chief, _) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        AppActions.bind(f.services)
        @MainActor func move(_ id: ActionID) { _ = f.services.registry.perform(id, invocation: ActionInvocation(origin: .user)) }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.controller.dockChiefPanel(at: .left)
        f.frame()
        try #require(f.controller.frameChiefPanelShown && !f.controller.frameChiefPanelHasKeys)
        // k1 has two panes side by side: from the right one, left reaches the left one, then the Chief.
        move("focusRight")
        move("focusLeft")
        f.frame()
        #expect(!f.controller.frameChiefPanelHasKeys, "one move left from the right pane skipped the left pane")
        move("focusLeft")
        f.frame()
        #expect(f.controller.frameChiefPanelHasKeys, "Cmd-Ctrl-H off the stage's left edge did not reach the docked Chief")
        move("focusLeft")
        #expect(f.controller.frameChiefPanelHasKeys, "a move into the window's edge left the Chief")
        move("focusRight")
        f.frame()
        #expect(!f.controller.frameChiefPanelHasKeys, "Cmd-Ctrl-L did not leave the docked Chief")
        let leftPane = f.services.workspace(id: "k1")?.screens.first?.panes.first?.id
        #expect(f.controller.content?.focus.state.pane == leftPane, "the move out did not land in the pane next to the Chief")

        #expect(f.controller.floatChiefPanel()) // in its own window, on one side of the cmux window's middle
        f.frame()
        let launcher = try #require(f.controller.chiefPanelView?.launcher), window = try #require(f.controller.window)
        let (toward, back): (ActionID, ActionID) = launcher.frame.midX >= window.frame.midX ? ("focusRight", "focusLeft") : ("focusLeft", "focusRight")
        move(toward)
        move(toward)
        f.frame()
        #expect(f.controller.frameChiefPanelHasKeys, "a move off the stage toward the floating Chief did not reach it")
        move(back)
        f.frame()
        #expect(!f.controller.frameChiefPanelHasKeys, "a move from the floating Chief did not go back to the stage")
    }

    /// Esc hides the floating Chief while it has the keys; dragged and resized, it keeps its place across a hide, a
    /// dock and the window record (a relaunch, which brings it back closed).
    @Test func escHidesTheFloatingChiefAndItRemembersItsPlace() async throws {
        let (chief, state) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        let view = try #require(f.controller.chiefPanelView)
        let launcher = try #require(view.launcher)
        try ChiefPanelStyleWindowTests.drag(view, by: CGVector(dx: -120, dy: -60), in: f)
        // Where it was left, kept on the screen when it comes back (a small screen pushes a drag past its edge).
        let moved = ChiefLauncherPanel.placement(saved: launcher.frame, in: try #require(launcher.screen?.visibleFrame))
        f.controller.dockChiefPanel(at: .right)
        f.frame()
        #expect(f.controller.floatChiefPanel())
        f.frame()
        #expect(launcher.frame == moved, "a dock and float lost the floating place: \(moved) -> \(launcher.frame)")
        let saved = try #require(f.state.chiefPanel.record)
        let data = try JSONEncoder().encode(saved)
        let restored = ChiefPanel(record: try JSONDecoder().decode(WindowChiefPanelRecord.self, from: data))
        var hidden = f.state.chiefPanel
        hidden.hide()
        #expect(restored == hidden, "the window record does not bring the panel back where it was")
        #expect(!restored.isOpen, "a relaunch shows the Chief (cmux#37365: never pinned at launch)")

        try #require(launcher.makeFirstResponder(state.draft))
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: launcher.windowNumber, context: nil,
                                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(view.performKeyEquivalent(with: esc), "Esc did not reach the floating Chief")
        f.frame()
        #expect(!f.controller.frameChiefPanelShown, "Esc did not hide the floating Chief")
        f.controller.toggleChiefPanel()
        f.frame()
        #expect(launcher.frame == moved, "the window did not reopen where it was: \(launcher.frame)")
        state.expectKept(in: chief, "after Esc and reopening")
    }

    // MARK: - The real Chief view and its answer (user 2026-11-07)

    /// `tree()` with Home's Chief tab as the app makes it: Home's page tab (`WorkspaceModel.homeDockPage`).
    static func pageTree() -> DaemonTree {
        var tree = tree()
        var page = TabSnapshot(surface: SurfaceID(rawValue: 901), kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: WorkspaceModel.homeDockPage)
        tree.workspaces[0].screens[0].panes[0].tabs = [page]
        return tree
    }

    /// With no stand-in, the panel finds Home's real Chief view (Home's page in its pane, the bug the real-app shots
    /// caught: the panel looked for a conversation view and showed nothing), floats that same view over the
    /// workspace a link opens, and gives it back to Home's pane when Home shows again.
    @Test func theRealHomeChiefViewFloatsAndGoesBackToHome() async throws {
        let f = try await Fixture(keys: Self.keys, tree: Self.pageTree())
        defer { f.close() }
        // Home's page provider, as the app registers it at launch (AppActions+Workspaces).
        f.services.pages.register(HomeDockTab(services: f.services))
        f.services.windows.show(workspaceID: "k2", in: f.state, from: .thisWindow)
        f.frame()
        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
        f.frame()
        try #require(f.controller.content?.workspace.id == "k0" && f.controller.frameHome == "k0", "the window does not show Home")
        let pane = try #require(f.controller.content?.panes.values.first, "Home has no pane")
        let home = try #require(pane.view.content, "Home's pane shows nothing")
        #expect(home is InternalPageView, "Home's Chief tab is not its page: \(type(of: home))")

        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        #expect(f.controller.frameChiefPanelShown, "the link opened no Chief over the workspace")
        #expect(f.controller.chiefPanelView?.chief === home, "the panel does not hold Home's own Chief view")

        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
        f.frame()
        #expect(!f.controller.frameChiefPanelShown, "the Chief shows over Home")
        let back = try #require(f.controller.content?.panes.values.first)
        #expect(back.view.content === home, "Home's pane did not get its Chief view back")
        #expect(home.window === f.controller.window && !home.isHiddenOrHasHiddenAncestor, "Home's Chief view is not on screen")
    }

    /// A stand-in for the Chief's view that is answering until told otherwise, with a message box for the keys.
    final class AnsweringChief: NSView, ChiefPanelContent {
        var chiefIsAnswering = true
        let box = NSTextView(frame: NSRect(x: 8, y: 8, width: 220, height: 40))
        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
            addSubview(box)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
    }

    /// Esc while the Chief answers stops the answer (Stop Chief, the path of the Stop button and Cmd-.) and keeps the
    /// panel; once the answer ended, Esc hides it. The Chief is inside Home's page, as in the app.
    @Test func escStopsAnAnsweringChiefInsteadOfHidingIt() async throws {
        let answering = AnsweringChief()
        let page = InternalPageView(key: "chief-page", page: .homeDock, content: answering)
        page.frame = answering.frame
        let f = try await Self.fixture(page)
        defer { f.close() }
        var stops = 0
        f.services.registry.bind("home.stopChief", invoke: { _ in stops += 1 })
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        let view = try #require(f.controller.chiefPanelView)
        try #require(f.controller.frameChiefPanelShown)
        try #require(view.window?.makeFirstResponder(answering.box) == true)
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(view.performKeyEquivalent(with: esc), "Esc did not reach the panel")
        f.frame()
        #expect(stops == 1, "Esc did not stop the answering Chief")
        #expect(f.controller.frameChiefPanelShown, "Esc hid the panel while the Chief was answering")

        answering.chiefIsAnswering = false
        #expect(view.performKeyEquivalent(with: esc))
        f.frame()
        #expect(stops == 1, "Esc stopped a Chief that was not answering")
        #expect(!f.controller.frameChiefPanelShown, "Esc did not hide the panel once the answer ended")
    }

    // MARK: - cmux#37372

    /// No link clicked in the Chief docks it (cmux#37372: "opening a subagent must never re-dock Chief"): after the
    /// person docked the panel, the next link from Home (a subagent chip, an `aN` or `cmux://` link) opens it
    /// floating over its workspace, never docked at its edge.
    @Test func aLinkFromHomeOpensTheChiefFloatingEvenAfterItWasDocked() async throws {
        let (chief, state) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state) // a link's jump
        f.frame()
        f.controller.dockChiefPanel(at: .left) // the person docks it
        f.frame()
        try #require(f.state.chiefPanel.dockedEdge == .left)

        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow) // back to Home
        f.frame()
        f.controller.armChiefPanel() // a subagent chip clicked in Home's chat
        f.services.windows.show(workspaceID: "k2", in: f.state)
        f.frame()
        #expect(f.controller.frameChiefPanelShown, "the link did not open the Chief over its workspace")
        #expect(f.state.chiefPanel.dockedEdge == nil, "a link re-docked the Chief at \(String(describing: f.state.chiefPanel.dockedEdge))")
        #expect(f.state.docks.isEmpty, "the link docked a workspace")
        #expect(f.controller.content?.contentView.frame == f.controller.root.contentHost.bounds, "the stage gave space to a docked Chief")
        state.expectKept(in: chief, "after the link")
    }

    /// Undock Chief (cmux#37372: "Chief needs a direct, obvious undock action"; palette, the Chief pane's ⋮ menu,
    /// `cmux home undock-chief`) floats a docked Chief over the stage, which takes the whole area back; with the
    /// Chief not docked it refuses and says why.
    @Test func undockChiefFloatsTheDockedChief() async throws {
        let (chief, _) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        AppActions.bind(f.services)
        f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
        f.controller.dockChiefPanel(at: .left)
        f.frame()
        try #require(f.state.chiefPanel.dockedEdge == .left && f.controller.frameChiefPanelShown)

        #expect(f.services.registry.perform("home.undockChief", invocation: ActionInvocation(origin: .user)))
        f.frame()
        #expect(f.state.chiefPanel.dockedEdge == nil, "Undock Chief left it docked")
        #expect(f.controller.frameChiefPanelShown, "Undock Chief hid the Chief instead of floating it")
        #expect(f.controller.content?.contentView.frame == f.controller.root.contentHost.bounds, "the stage did not take the area back")

        let again = f.services.registry.capturingRefusal {
            _ = f.services.registry.perform("home.undockChief", invocation: ActionInvocation(origin: .user))
        }
        #expect(again == RefusalStrings.chiefNotDocked, "Undock Chief with the Chief floating: \(again ?? "ran")")
    }

    /// Undock Chief on a docked Chief the person hid (Cmd-I) floats it and shows it: the action never reports done
    /// with nothing visible.
    @Test func undockChiefShowsAHiddenDockedChief() async throws {
        let (chief, _) = Self.chiefView()
        let f = try await Self.fixture(chief)
        defer { f.close() }
        AppActions.bind(f.services)
        f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
        f.controller.dockChiefPanel(at: .left)
        f.controller.hideChiefPanel()
        f.frame()
        try #require(f.state.chiefPanel.dockedEdge == .left && !f.controller.frameChiefPanelShown)

        #expect(f.services.registry.perform("home.undockChief", invocation: ActionInvocation(origin: .user)))
        f.frame()
        #expect(f.state.chiefPanel.dockedEdge == nil, "Undock Chief left the hidden Chief docked")
        #expect(f.controller.frameChiefPanelShown, "Undock Chief left the Chief hidden")
    }
}
