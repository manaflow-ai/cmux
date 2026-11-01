import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-19: Move to New Window for tabs, tab groups, panes,
/// workspaces and workspace groups. Each runs its registered action (the
/// path the right-click, the palette, the CLI and MCP share) against a
/// same-tree cmux-tui daemon and checks what moved: the content shows in a
/// new window beside the old one; its terminals keep their daemon terminal
/// (same id, same incarnation: never restarted); its browser tabs keep their
/// page entry (reparented, never reloaded); and no window is left empty.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct MoveToNewWindowTests {
    /// What must survive a move, per tab.
    struct Live {
        let tab: String
        let terminal: TerminalID?
        let incarnation: TerminalIncarnation?
        let browser: BrowserEntry?

        @MainActor init(_ tab: TabModel, _ services: AppServices) {
            self.tab = tab.id
            terminal = tab.terminalID
            incarnation = tab.terminalIncarnation
            browser = services.cache.existingBrowser(tab.id)
        }
    }

    @Test func aTabMovesToANewWindowAlive() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try Self.firstPane(services)
            let terminal = try #require(pane.tabs.first)
            let browser = try await Self.browserTab(in: pane, services, connection)
            let source = try Self.window(ofTab: browser.id, services)
            let frame = services.windows.controller(for: source)?.window?.frame
            let live = Live(browser, services)
            #expect(services.registry.perform("tab.moveToNewWindow", invocation: Self.on(.tab, browser.id)))
            try await Self.expectMoved([live], from: source, frame: frame, services)
            // The terminal tab stayed in the source window, which stays open.
            #expect(try Self.window(ofTab: terminal.id, services) == source)
        }
    }

    @Test func aTabGroupMovesToANewWindowAlive() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try Self.firstPane(services)
            let browser = try await Self.browserTab(in: pane, services, connection)
            #expect(services.registry.perform("tabGroup.create", invocation: Self.on(.tab, browser.id)))
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: browser.surface)?.tabGroup != nil })
            let group = try #require(browser.tabGroup)
            let source = try Self.window(ofTab: browser.id, services)
            let frame = services.windows.controller(for: source)?.window?.frame
            let live = Live(browser, services)
            #expect(services.registry.perform("tabGroup.moveToNewWindow", invocation: Self.on(.tabGroup, group.rawValue)))
            try await Self.expectMoved([live], from: source, frame: frame, services)
        }
    }

    @Test func aPaneMovesToANewWindowWithAllItsTabsAlive() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let first = try Self.firstPane(services)
            let workspace = try #require(services.daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === first } } })
            let created = try await connection.newTab(in: first.handle)
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil })
            #expect(services.registry.perform("splitRight", invocation: Self.on(.pane, first.id)))
            // The daemon's split, not its stand-in (`ProvisionalPane`), which shows first: a move
            // before the daemon has the split left the stand-in and the daemon's pane both behind.
            try await PinnedPageTests.until({
                let panes = workspace.screens.flatMap(\.panes)
                return panes.count == 2 && panes.allSatisfy { $0.tabs.allSatisfy { !ProvisionalTab.isProvisional(surface: $0.surface) } }
            })
            // The pane that moves: the first one, with its two tabs; the new split stays.
            let moving = first.tabs.map { Live($0, services) }
            #expect(moving.count == 2)
            let source = try Self.window(ofTab: moving[0].tab, services)
            let frame = services.windows.controller(for: source)?.window?.frame
            #expect(services.registry.perform("pane.moveToNewWindow", invocation: Self.on(.pane, first.id)))
            try await Self.expectMoved(moving, from: source, frame: frame, services)
            // The source's layout reports the pane gone in its own batch, after the new window's.
            try await PinnedPageTests.until({ workspace.screens.flatMap(\.panes).count == 1 },
                                            report: { "the split stays behind: \(workspace.screens.flatMap(\.panes).count) panes" })
        }
    }

    /// A pane that is its workspace's only pane moves the workspace (nothing
    /// is left behind to keep), and the window it leaves, now empty, is gone.
    @Test func aWindowsOnlyPaneMovesItsWorkspaceAndLeavesNoEmptyWindow() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try await Self.newWorkspace(services)
            #expect(services.registry.perform("moveWorkspaceToNewWindow", invocation: Self.on(.workspace, workspace.id)))
            try await PinnedPageTests.until({ services.windows.controllers.count == 2 })
            let pane = try #require(workspace.screens.first?.panes.first)
            let moving = pane.tabs.map { Live($0, services) }
            let source = try Self.window(ofTab: moving[0].tab, services)
            let frame = services.windows.controller(for: source)?.window?.frame
            let windows = services.windows.controllers.count
            #expect(services.registry.perform("pane.moveToNewWindow", invocation: Self.on(.pane, pane.id)))
            try await Self.expectMoved(moving, from: source, frame: frame, services, sourceEmptied: true)
            #expect(services.windows.controllers.count == windows, "a window was left empty, or a second opened")
        }
    }

    @Test func aWorkspaceMovesToANewWindowAlive() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try await Self.newWorkspace(services)
            let moving = workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { Live($0, services) }
            let source = try Self.window(ofTab: moving[0].tab, services)
            let frame = services.windows.controller(for: source)?.window?.frame
            #expect(services.registry.perform("moveWorkspaceToNewWindow", invocation: Self.on(.workspace, workspace.id)))
            try await Self.expectMoved(moving, from: source, frame: frame, services)
        }
    }

    @Test func aWorkspaceGroupMovesToANewWindowAlive() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try await Self.newWorkspace(services)
            let name = "move-me-\(UUID().uuidString.prefix(6))"
            #expect(services.registry.perform("workspace.moveToNewGroup",
                                              invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace.id),
                                                                           arguments: ["name": .string(name)], origin: .user)))
            let personal = services.daemon.store.personal
            // A personal group's members are in the personal store (not on `WorkspaceModel.group`).
            @MainActor func group() -> WorkspaceGroupID? {
                personal.groups.first { $0.name == name }.flatMap { group in
                    personal.workspaces.contains { $0.workspaceKey.rawValue == workspace.id && $0.group == group.id } ? group.id : nil
                }
            }
            try await PinnedPageTests.until({ group() != nil }, within: .seconds(40), report: {
                "daemon groups \(personal.groups.map { ($0.name, $0.id.rawValue) }); placements \(personal.workspaces.map { ($0.workspaceKey.rawValue, $0.group?.rawValue ?? "-") }); workspace \(workspace.id)"
            })
            let group = try #require(group())
            let moving = workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { Live($0, services) }
            let source = try Self.window(ofTab: moving[0].tab, services)
            let frame = services.windows.controller(for: source)?.window?.frame
            #expect(services.registry.perform("workspaceGroup.moveToNewWindow", invocation: Self.on(.workspaceGroup, group.rawValue)))
            try await Self.expectMoved(moving, from: source, frame: frame, services)
        }
    }

    /// v2.2.6-opt gate (mw-restart-three-windows; handoff/v224-gate-triage.md): two Move to New Window from one window
    /// opened both new windows at the same frame ([438, 242, 1100, 720] when the source had no room beside it), so the
    /// second hid the first completely. A new window never opens exactly on a window already there: it steps on from
    /// it, as AppKit's `cascadeTopLeft(from:)` does.
    @Test func twoMovesFromOneWindowOpenTwoWindowsThatDoNotCoverEachOther() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let first = try await Self.newWorkspace(services)
            let second = try await Self.newWorkspace(services)
            let source = try Self.window(ofTab: try #require(first.screens.first?.panes.first?.tabs.first).id, services)
            #expect(services.registry.perform("moveWorkspaceToNewWindow", invocation: Self.on(.workspace, first.id)))
            try await PinnedPageTests.until({ services.windows.controllers.count == 2 })
            // Back to the source window, as the gate journey moves both workspaces out of window 1.
            if let window = services.windows.controller(for: source) { services.windows.bringToFront(window) }
            #expect(services.registry.perform("moveWorkspaceToNewWindow", invocation: Self.on(.workspace, second.id)))
            try await PinnedPageTests.until({ services.windows.controllers.count == 3 })
            let frames = services.windows.controllers.compactMap { $0.window?.frame }
            let origins = Set(frames.map { "\(Int($0.minX)),\(Int($0.minY))" })
            #expect(origins.count == frames.count, "two windows opened on the same frame: \(frames)")
        }
    }

    /// The placement rule: beside the source on its right when the screen
    /// has room, else on its left, else cascaded; always on the screen.
    @Test func theNewWindowOpensBesideTheOldOne() {
        let screen = CGRect(x: 0, y: 0, width: 3000, height: 1000)
        let placement = MovedWindowPlacement()
        let left = CGRect(x: 100, y: 100, width: 1000, height: 700)
        #expect(placement.frame(beside: left, on: screen) == CGRect(x: 1100 + placement.gap, y: 100, width: 1000, height: 700))
        let right = CGRect(x: 1900, y: 100, width: 1000, height: 700)
        #expect(placement.frame(beside: right, on: screen) == CGRect(x: 900 - placement.gap, y: 100, width: 1000, height: 700))
        let wide = CGRect(x: 200, y: 200, width: 2600, height: 700)
        let cascaded = placement.frame(beside: wide, on: screen)
        #expect(cascaded.size == wide.size && cascaded != wide && screen.contains(cascaded))
    }

    /// A source window that fills its screen (zoomed) or nearly fills it leaves no room to cascade on the screen: the
    /// cascade wrapped back to the spot a window already took, so the second move from a zoomed window still opened
    /// exactly on the first (review of #30011). Every move gets a spot of its own, partly off screen if it must.
    @Test(arguments: [CGRect(x: 0, y: 0, width: 1512, height: 944), CGRect(x: 20, y: 20, width: 1480, height: 900),
                      CGRect(x: 206, y: 112, width: 1100, height: 720)])
    func threeMovesFromOneWindowEachGetASpotOfTheirOwn(source: CGRect) {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        var open = [source]
        for _ in 0..<3 { open.append(MovedWindowPlacement().frame(beside: source, on: screen, avoiding: open)) }
        let spots = Set(open.map { "\(Int($0.minX.rounded())),\(Int($0.maxY.rounded()))" })
        #expect(spots.count == open.count, "two windows share a top-left: \(open)")
    }

    // MARK: Helpers

    static func on(_ kind: ActionTargetKind, _ id: String) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: kind, id: id), origin: .user)
    }

    static func firstPane(_ services: AppServices) throws -> PaneModel {
        try #require(services.daemon.store.workspaces.first { $0.kind == nil }?.screens.first?.panes.first
            ?? services.daemon.store.workspaces.first?.screens.first?.panes.first)
    }

    static func window(ofTab id: String, _ services: AppServices) throws -> String {
        let workspace = try #require(services.workspaceID(ofTab: id), "tab \(id) has no workspace")
        return try #require(services.windows.registry.value.owner(of: workspace), "workspace \(workspace) has no window")
    }

    /// A WebKit tab in `pane`, selected so its page entry exists.
    static func browserTab(in pane: PaneModel, _ services: AppServices, _ connection: DaemonConnection) async throws -> TabModel {
        let created = try await connection.newFrontendBrowserTab(url: "about:blank", engine: .webkit, in: pane.handle, activate: true)
        try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil })
        try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface)?.resourceID != nil })
        let tab = try #require(services.daemon.store.tab(surface: created.surface))
        // The page entry the pane shows (made on first show; no window is ordered in here).
        _ = try #require(services.cache.browser(for: tab), "no page entry for \(tab.id)")
        return tab
    }

    /// A second terminal workspace in the active window, once its tab is mirrored.
    static func newWorkspace(_ services: AppServices) async throws -> WorkspaceModel {
        let window = services.windows.active?.state.id
        let id = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "move-me"), into: window)
        try await PinnedPageTests.until({ services.workspace(id: id)?.screens.first?.panes.first?.tabs.isEmpty == false })
        return try #require(services.workspace(id: id))
    }

    /// Every tab of `live` shows in one window other than `source` (or, when
    /// the move emptied `source`, in the window that replaced it), placed
    /// beside the old frame, with its terminal and page entry unchanged.
    static func expectMoved(_ live: [Live], from source: String, frame sourceFrame: CGRect?, _ services: AppServices, sourceEmptied: Bool = false,
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        func target() -> String? {
            let owners = Set(live.compactMap { try? window(ofTab: $0.tab, services) })
            guard owners.count == 1, let owner = owners.first else { return nil }
            return sourceEmptied || owner != source ? owner : nil
        }
        try await PinnedPageTests.until({ target() != nil && (sourceEmptied || services.windows.controller(for: target()!) != nil) },
                                        report: { "tabs \(live.map(\.tab)) are in \(live.map { (try? window(ofTab: $0.tab, services)) ?? "-" })" },
                                        sourceLocation: sourceLocation)
        let moved = try #require(target())
        for entry in live {
            let tab = try #require(services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.id == entry.tab },
                                   "tab \(entry.tab) closed", sourceLocation: sourceLocation)
            #expect(tab.terminalID == entry.terminal, "\(entry.tab): a new terminal", sourceLocation: sourceLocation)
            #expect(tab.terminalIncarnation == entry.incarnation, "\(entry.tab): the terminal restarted", sourceLocation: sourceLocation)
            if let browser = entry.browser {
                #expect(services.cache.existingBrowser(entry.tab) === browser, "\(entry.tab): the page reloaded", sourceLocation: sourceLocation)
            }
        }
        // Nothing left empty: every open window lists a workspace.
        for controller in services.windows.controllers where controller.window?.isVisible != false {
            #expect(!services.windows.registry.members(of: controller.state.id).isEmpty, "window \(controller.state.id) is empty",
                    sourceLocation: sourceLocation)
        }
        if let sourceFrame, let frame = services.windows.controller(for: moved)?.window?.frame {
            #expect(frame.origin != sourceFrame.origin, "the new window covers the old one", sourceLocation: sourceLocation)
        }
    }
}
