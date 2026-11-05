import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Reveal Workspace in Sidebar (Lawrence msg 20167: "we need a cmd shift p command like focus in sidebar/scroll to in
/// sidebar which is im in a workspaces and i want to see it in sidebar so i know where it is"). The palette, the row
/// menu and a shortcut all run `sidebar.revealWorkspace`, whose one path is `SidebarView.revealWorkspace`: the folds
/// that hide the row open, the row scrolls into the middle of the list and flashes, and keyboard focus stays put.
/// Reveal and Focus (`sidebar.revealAndFocusWorkspace`) then moves focus to the list through Focus Sidebar; the last
/// test runs both actions through the App's own bindings.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRevealInSidebarTests {
    static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func ws(_ id: String, archived: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        row.isArchived = archived
        return row
    }

    static func group(_ id: String, parent: String? = nil, _ members: [SidebarWorkspace]) -> SidebarNode {
        var group = SidebarGroup(id: GroupID(id), name: id.capitalized, color: .blue, isCollapsed: true, workspaces: members)
        group.parent = parent.map(GroupID.init)
        return .group(group)
    }

    /// 30 rows, group Outer (collapsed: o1) with its subgroup Inner (collapsed: deep), 20 more rows, and the
    /// archived row old, which the closed Archive at the bottom holds.
    static func sections() -> [CmuxNextSidebar.SidebarSection] {
        let above = (1...30).map { SidebarNode.workspace(ws("a\($0)")) }
        let below = (1...20).map { SidebarNode.workspace(ws("b\($0)")) }
        return [CmuxNextSidebar.SidebarSection(kind: .machine(local), nodes: above + [
            group("outer", [ws("o1")]),
            group("inner", parent: "outer", [ws("deep")]),
        ] + below + [.workspace(ws("old", archived: true))])]
    }

    struct Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let content: NSTextView
        var list: SidebarListView { sidebar.list }
    }

    /// A 240 x 320 sidebar beside a text view that has keyboard focus, `active` the window's current workspace.
    static func harness(active: String) throws -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(), activeWorkspaceID: WorkspaceID(active))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSTextView(frame: NSRect(x: 240, y: 0, width: 240, height: 320))
        window.contentView?.addSubview(sidebar)
        window.contentView?.addSubview(content)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        window.makeFirstResponder(content)
        try #require(sidebar.list.enclosingScrollView?.contentView.bounds.height ?? 0 > 0)
        return Harness(model: model, sidebar: sidebar, window: window, content: content)
    }

    /// Whether row `id` is drawn and centred in the list's viewport (a row out of view comes to the middle).
    static func isCentred(_ list: SidebarListView, _ id: String) throws -> Bool {
        let clip = try #require(list.enclosingScrollView?.contentView)
        let row = try #require(list.displayed.row(for: .workspace(WorkspaceID(id))))
        return abs((row.y + row.height / 2) - clip.bounds.midY) < 1
    }

    @Test func revealOpensTheNestedGroupsScrollsTheRowToTheMiddleAndFlashesItAtOnceUnderReduceMotion() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = try Self.harness(active: "deep")
        defer { h.window.close() }
        h.model.presentation = .hidden
        try #require(h.list.displayed.row(for: .workspace(WorkspaceID("deep"))) == nil, "the row starts hidden in its folds")

        #expect(h.sidebar.revealWorkspace(WorkspaceID("deep")))

        #expect(h.model.presentation == .shown, "a hidden sidebar shows")
        #expect(h.model.group(GroupID("outer"))?.isCollapsed == false, "the outer group opens")
        #expect(h.model.group(GroupID("inner"))?.isCollapsed == false, "the nested group opens")
        #expect(try Self.isCentred(h.list, "deep"), "the row scrolls to the middle of the list")
        let flash = try #require(h.list.revealFlash, "the row flashes")
        #expect(flash.key == .workspace(WorkspaceID("deep")))
        #expect(!flash.isAnimated, "under Reduce Motion the flash shows at once, with no animation")
        #expect(flash.isShowing)
        #expect(h.window.firstResponder === h.content, "keyboard focus stays in the workspace")
    }

    @Test func revealFromTheRowMenuOpensTheArchiveForAnArchivedWorkspace() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = try Self.harness(active: "a1")
        defer { h.window.close() }
        try #require(h.list.displayed.row(for: .workspace(WorkspaceID("old"))) == nil, "the closed Archive holds the row")

        #expect(h.sidebar.revealWorkspace(WorkspaceID("old")), "the row menu reveals the row it was opened on")

        #expect(h.list.openDoneFolds.contains(.archive), "the Archive opens")
        let clip = try #require(h.list.enclosingScrollView?.contentView)
        let drawn = try #require(h.list.displayed.row(for: .workspace(WorkspaceID("old"))), "the archived row is drawn")
        #expect(drawn.y >= clip.bounds.minY - 0.5 && drawn.y + drawn.height <= clip.bounds.maxY + 0.5, "and in view")
        #expect(h.list.revealFlash?.key == .workspace(WorkspaceID("old")))
        #expect(h.window.firstResponder === h.content)
    }

    @Test func theFlashBlinksWhenCmuxAnimates() throws {
        let design = DesignSettings.shared
        let saved = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed, Motion.reduceMotionOverride)
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .normal
        Motion.reduceMotionOverride = false
        defer {
            design.animationsEnabled = saved.0
            design.disabledAnimationCategories = saved.1
            design.animationSpeed = saved.2
            Motion.reduceMotionOverride = saved.3
        }
        let h = try Self.harness(active: "deep")
        defer { h.window.close() }
        try #require(Motion.sidebar.animatesLoops)

        #expect(h.sidebar.revealWorkspace(WorkspaceID("deep")))

        let flash = try #require(h.list.revealFlash)
        #expect(flash.isAnimated, "with animations on the row blinks")
        #expect(h.window.firstResponder === h.content)
    }

    @Test func aWorkspaceTheSidebarDoesNotListIsRefused() throws {
        let h = try Self.harness(active: "a1")
        defer { h.window.close() }
        #expect(!h.sidebar.revealWorkspace(WorkspaceID("elsewhere")))
        #expect(h.list.revealFlash == nil)
        #expect(h.window.firstResponder === h.content)
    }

    /// One workspace in the App's own window, its sidebar hidden: the palette's run of each action through the App's
    /// bindings (`AppActions.bind`, `SidebarActionSet`).
    @Test func theAppsActionsRevealTheCurrentWorkspaceAndOnlyRevealAndFocusMovesTheKeyboard() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "reveal-ws"), name: "reveal"),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "reveal-ws"), index: 0)])
        store.apply(snapshot: tree)
        let controller = try #require(services.windows.openWindow(workspaces: ["reveal-ws"], frame: CGRect(x: 200, y: 200, width: 1000, height: 700)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)
        let sidebar = controller.sidebar.container.sidebarView
        try await PasswordManagerRouteTests.until({ sidebar.model.activeWorkspaceID.map(sidebar.model.lists) == true },
                                                  report: { "the sidebar never listed the window's workspace" })
        let active = try #require(sidebar.model.activeWorkspaceID)
        sidebar.model.toggle()
        try #require(sidebar.model.isHidden)
        let before = window.firstResponder

        #expect(services.registry.perform("sidebar.revealWorkspace", invocation: ActionInvocation()))
        #expect(!sidebar.model.isHidden, "the hidden sidebar shows")
        #expect(sidebar.list.revealFlash?.key == .workspace(active), "the current workspace's row flashes")
        #expect(window.firstResponder === before, "Reveal leaves keyboard focus where it was")

        sidebar.list.revealFlash?.remove()
        #expect(services.registry.perform("sidebar.revealAndFocusWorkspace", invocation: ActionInvocation()))
        #expect(sidebar.list.revealFlash?.key == .workspace(active))
        #expect(window.firstResponder === sidebar.list, "Reveal and Focus gives the workspace list the keyboard")
    }
}
