import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Lawrence 2026-10-20: "I think Command-D in home does not work. We need to make it work. I think
/// there's a ton of edge cases like this." Home opens as its pinned chat dock alone
/// (`pinned-dock-alone-v1`): no scrolling column, so the split rule had no strip to send the new
/// tool to and refused ("The agent chat can't be split."). Cmd-D and Cmd-Shift-D there now open the
/// new pane in a column right of the dock, as New Tab does; the keys around them (focus, equalize,
/// close) then act on that column like any.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeSplitKeysTests {
    /// Shows the docked Home with its dock alone and focused; returns the window and the home workspace.
    private static func showHome(_ services: AppServices, _ connection: DaemonConnection) async throws -> (WindowController, WorkspaceModel) {
        try #require(!services.home.dock.isClassic, "the docked Home is the default")
        let window = try #require(services.windows.active)
        services.home.ensureHomeWorkspace(connection)
        try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                   report: { services.home.homeWorkspaceStep })
        let home = try #require(services.home.homeWorkspace)
        #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
        try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id && window.focusedPane != nil
            && Self.panes(home).count == 1 && window.focusedPane?.pane === Self.panes(home).first }, within: .seconds(60), report: {
            "workspace \(String(describing: window.state.workspaceID)), panes \(Self.panes(home).count), step \(services.home.homeWorkspaceStep)"
        })
        return (window, home)
    }

    private static func panes(_ home: WorkspaceModel) -> [PaneModel] { home.screens.flatMap(\.panes) }

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

    /// Once a pane is beside the dock, the split, focus, equalize and close keys act on it like on any
    /// pane: Cmd-D splits it in place, Cmd-Opt-Left reaches the dock, Equalize is not refused, and
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
            var refused = Self.refusals(services) {
                #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            }
            #expect(refused.isEmpty, "Cmd-D beside the dock was refused: \(refused)")
            try await PasswordManagerRouteTests.until({ Self.panes(home).count == 3 }, report: { "\(Self.panes(home).count) panes" })
            refused = Self.refusals(services) {
                _ = services.registry.perform("equalizeSplits", invocation: ActionInvocation(origin: .user))
            }
            #expect(refused.isEmpty, "Equalize in Home was refused: \(refused)")
            try await PasswordManagerRouteTests.until({ window.focusedPane?.pane === Self.panes(home).last })
            for _ in 0..<2 { _ = services.registry.perform("focusLeft", invocation: ActionInvocation(origin: .user)) }
            try await PasswordManagerRouteTests.until({ window.focusedPane?.pane === dock }, report: {
                "focused \(String(describing: window.focusedPane?.paneKey))"
            })
            for pane in Self.panes(home) where pane !== dock {
                _ = services.registry.perform("closePane", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), origin: .user))
            }
            try await PasswordManagerRouteTests.until({ Self.panes(home).count == 1 && Self.panes(home).first === dock },
                                                       report: { "\(Self.panes(home).count) panes" })
        }
    }
}
