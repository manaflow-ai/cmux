import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextHomeEngine
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-20: "I think Command-D in home does not work. We need to make it work. I think
/// there's a ton of edge cases like this." Home opens as its pinned chat dock alone
/// (`pinned-dock-alone-v1`): no scrolling column, so the split rule had no strip to send the new
/// tool to and refused ("The agent chat can't be split."). Cmd-D and Cmd-Shift-D there now open the
/// new pane in a column right of the dock, as New Tab does; the keys around them (focus, equalize,
/// close) then act on that column like any.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct HomeSplitKeysTests {
    /// Shows the docked Home with its dock alone and focused; returns the window and the home workspace.
    static func showHome(_ services: AppServices, _ connection: DaemonConnection) async throws -> (WindowController, WorkspaceModel) {
        try #require(!services.home.dock.isClassic, "the docked Home is the default")
        let window = try #require(services.windows.active)
        services.home.ensureHomeWorkspace(connection)
        try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                   report: { services.home.homeWorkspaceStep })
        let home = try #require(services.home.homeWorkspace)
        let homeID = try #require(home.resourceID ?? services.home.homeWorkspaceID)
        // Home shows first: the dock move needs the window to lay out the home screen's columns.
        #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
        try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id && window.focusedPane != nil })
        // Home's own form: its page in the pinned chat dock, alone on the screen (`pinned-dock-alone-v1`).
        @MainActor func loneDock() -> Bool {
            guard window.state.workspaceID == home.id, let focused = window.focusedPane, Self.panes(home).count == 1,
                  focused.pane === Self.panes(home).first else { return false }
            return ChatDockRules.isChatDock(focused.pane, services: services)
                && ChatColumnPlacement.resolve(from: focused, services: services) == .besideDock
        }
        // The dock move, as the home service runs it on connect before it waits for the Chief owner
        // (which this harness has none of). It is idempotent; each answer goes in the report.
        var dockSteps: [String] = []
        for _ in 0..<10 where !loneDock() {
            dockSteps.append(await services.home.dock.ensure(connection, store: services.daemon.store, home: homeID) {
                TabMoves.toNewDockColumn($0, anchor: $1, edge: .left, role: .agentChat, respawn: $2, pinned: $3, services: services, completion: $4)
            })
            if let placed = HomeDock.pageTab(in: home) {
                let docked = ChatDockRules.isChatDock(placed.pane, services: services)
                if !docked, placed.pane.tabs.count == 1 {
                    // A real Home's page joined the shell its workspace opened with; the daemon never
                    // splits a pane's only tab out of it ("a pane's only tab cannot be split out").
                    // The dock move can drop that pane before the tree reports it ("unknown pane"):
                    // the next round reads the tree again.
                    do {
                        _ = try await connection.newTab(in: placed.pane.handle)
                        dockSteps.append("added the shell a real Home starts with")
                    } catch { dockSteps.append("adding the shell: \(error)") }
                } else if docked {
                    // The dock is made: what is left on its right is that shell; Home stands alone.
                    let right = Self.panes(home).filter { $0 !== placed.pane }.flatMap(\.tabs).map(\.surface)
                    if !right.isEmpty {
                        do {
                            try await connection.closeTabs(right, endTerminals: true)
                            dockSteps.append("closed \(right.count) tab(s) right of the dock")
                        } catch { dockSteps.append("closing the shell: \(error)") }
                    } else if window.focusedPane?.pane !== placed.pane, let content = window.content,
                              let id = content.handles.paneIDs[placed.pane.handle] {
                        PaneHandlers.focus(id, in: content)
                    }
                }
            }
            // test harness: the tree reports the move a few events later (as `until`, without its issue)
            let deadline = ContinuousClock.now + .seconds(3)
            while !loneDock(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(loneDock(), """
            Home never became its lone pinned dock: workspace \(String(describing: window.state.workspaceID)), panes \(Self.panes(home).count), \
            dock \(window.focusedPane.map { ChatDockRules.isChatDock($0.pane, services: services) } ?? false), \
            placement \(window.focusedPane.map { String(describing: ChatColumnPlacement.resolve(from: $0, services: services)) } ?? "-"), \
            dock steps \(dockSteps), step \(services.home.homeWorkspaceStep)
            """)
        return (window, home)
    }

    static func panes(_ home: WorkspaceModel) -> [PaneModel] { home.screens.flatMap(\.panes) }

    /// Collects every refusal `body` causes.
    private static func refusals(_ services: AppServices, _ body: () -> Void) -> [String] {
        var seen: [String] = []
        let previous = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in seen.append(reason); previous?(reason, quiet) }
        defer { services.registry.refusalObserver = previous }
        body()
        return seen
    }

    /// Cmd-D (Split Right) and Cmd-Shift-D (Split Down) from Home's dock alone open one new pane right
    /// of the dock, never a refusal, and leave the dock as it was.
    @Test(arguments: ["splitRight", "splitDown"])
    func aSplitFromTheLoneHomeDockOpensAPaneBesideIt(_ action: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await Self.showHome(services, connection)
            let dock = try #require(Self.panes(home).first)
            let refused = Self.refusals(services) {
                #expect(services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user)))
            }
            #expect(refused.isEmpty, "\(action) in Home was refused: \(refused)")
            try await PasswordManagerRouteTests.until({ Self.panes(home).count == 2 }, report: {
                "\(Self.panes(home).count) panes, refused \(refused)"
            })
            #expect(Self.panes(home).first === dock, "the dock stays first")
            #expect(window.state.workspaceID == home.id && window.state.page == nil, "the window stays on Home")
            // The new pane takes the keys, as any split's does.
            try await PasswordManagerRouteTests.until({ window.focusedPane?.pane === Self.panes(home).last }, report: {
                "focused \(String(describing: window.focusedPane?.paneKey))"
            })
        }
    }

    /// Home's pinned dock, as the app makes it, takes tabs (`allow_tabs`, Leo 2026-10-21) but shows no
    /// tab strip while it holds only Home (Lawrence 2026-10-23: "home chief should have no tabbar"), and
    /// Show Tab Bar is refused there. A tab dragged in joins it after Home's tab, the strip shows while it
    /// is there so it stays reachable, and it drags out again. Only a drag: a new tab opens beside Home
    /// (HomeDockOpensTests).
    @Test func homesDockShowsNoTabStripAndTakesTabs() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (_, home) = try await Self.showHome(services, connection)
            let dock = try #require(Self.panes(home).first)
            @MainActor func dockFlag() -> DockSnapshot? {
                home.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(dock.handle) }?.dock
            }
            try await PasswordManagerRouteTests.until({ dockFlag()?.allowsTabs == true }, report: {
                "Home's dock: \(String(describing: dockFlag()))"
            })
            #expect(dockFlag()?.isPinned == true, "the dock stays pinned")
            let controller = try #require(services.paneController(for: dock))
            try await PasswordManagerRouteTests.until({ controller.view.hidesStrip }, report: { "Home's pane shows a tab strip" })
            #expect(PaneTabBarHandlers.noToggleReason(controller) != nil, "Show Tab Bar is offered in Home")
            let page = try #require(dock.tabs.first)
            #expect(page.page == HomeDock.page)
            // A terminal beside Home (the chat header's Terminal), plus a second tab there so its
            // column stays when the terminal leaves.
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            // The daemon's pane, not the split's stand-in (`ProvisionalPane`), which shows first and
            // whose handle the daemon does not know ("new-tab failed: unknown pane").
            try await PasswordManagerRouteTests.until({
                Self.panes(home).count == 2
                    && Self.panes(home).last?.tabs.first.map { !ProvisionalTab.isProvisional(surface: $0.surface) } == true
            }, report: { "\(Self.panes(home).count) panes, right tabs \(Self.panes(home).last?.tabs.map(\.surface) ?? [])" })
            let right = try #require(Self.panes(home).last)
            _ = try await connection.newTab(in: right.handle)
            try await PasswordManagerRouteTests.until({ right.tabs.count == 2 }, report: { "right of Home: \(right.tabs.count) tab(s)" })
            let terminal = try #require(right.tabs.first)
            let surface = terminal.surface
            // The drag paths: the terminal drags into Home, then back out to the pane right of Home.
            let refused = Self.refusals(services) {
                TabMoves.move(terminal, to: dock, index: 1, services: services)
            }
            #expect(refused.isEmpty, "a terminal dragged into Home was refused: \(refused)")
            try await PasswordManagerRouteTests.until({ dock.tabs.contains { $0.surface == surface } }, report: {
                "drag in: Home's dock holds \(dock.tabs.map(\.surface))"
            })
            #expect(dock.tabs.first?.surface == page.surface, "Home's tab stays first")
            try await PasswordManagerRouteTests.until({ !controller.view.hidesStrip }, report: { "a tab dragged into Home has no strip to reach it" })
            let moved = try #require(dock.tabs.first { $0.surface == surface })
            TabMoves.move(moved, to: right, index: 0, services: services)
            try await PasswordManagerRouteTests.until({ !dock.tabs.contains { $0.surface == surface } && right.tabs.contains { $0.surface == surface } },
                                                       report: { "drag out: Home's dock holds \(dock.tabs.map(\.surface))" })
            #expect(dock.tabs.first?.surface == page.surface, "Home's tab stays first")
            try await PasswordManagerRouteTests.until({ controller.view.hidesStrip }, report: { "Home alone again shows a tab strip" })
        }
    }

    /// Once a pane is beside the dock, the split, focus, equalize and close keys act on it like on any
    /// pane: Cmd-Shift-D splits it in place, Cmd-Opt-Left reaches the dock, Equalize is not refused, and
    /// closing the right side leaves the dock alone again.
    @Test func theKeysAroundASplitActBesideTheDock() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await Self.showHome(services, connection)
            let dock = try #require(Self.panes(home).first)
            // The chat header's Terminal: a terminal beside the dock, so the next Cmd-D is a terminal split.
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PasswordManagerRouteTests.until({ Self.panes(home).count == 2 && window.focusedPane?.pane === Self.panes(home).last
                && window.focusedPane?.selectedTab?.kind == .pty }, report: { "\(Self.panes(home).count) panes" })
            // Cmd-Shift-D in place (the test window is too narrow for a third column across: Cmd-D
            // there is refused for room, as on any narrow column).
            var refused = Self.refusals(services) {
                #expect(services.registry.perform("splitDown", invocation: ActionInvocation(origin: .user)))
            }
            #expect(refused.isEmpty, "Cmd-Shift-D beside the dock was refused: \(refused)")
            try await PasswordManagerRouteTests.until({ Self.panes(home).count == 3 }, report: { "\(Self.panes(home).count) panes" })
            refused = Self.refusals(services) {
                _ = services.registry.perform("equalizeSplits", invocation: ActionInvocation(origin: .user))
            }
            #expect(refused.isEmpty, "Equalize in Home was refused: \(refused)")
            // The new pane has the keys; Cmd-Opt-Left, one press at a time, walks back to the dock.
            try await PasswordManagerRouteTests.until({ window.focusedPane != nil && window.focusedPane?.pane !== dock })
            var path: [String] = []
            for _ in 0..<3 where window.focusedPane?.pane !== dock {
                let from = window.focusedPane?.pane
                _ = services.registry.perform("focusLeft", invocation: ActionInvocation(origin: .user))
                try await PasswordManagerRouteTests.until({ window.focusedPane?.pane !== from }, report: { "focusLeft did not move from \(path)" })
                path.append(window.focusedPane?.paneKey ?? "-")
            }
            #expect(window.focusedPane?.pane === dock, "Cmd-Opt-Left went \(path), never to the dock")
            for pane in Self.panes(home) where pane !== dock {
                _ = services.registry.perform("closePane", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), origin: .user))
            }
            try await PasswordManagerRouteTests.until({ Self.panes(home).count == 1 && Self.panes(home).first === dock },
                                                       report: { "\(Self.panes(home).count) panes" })
        }
    }
}
