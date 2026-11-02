import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import Foundation
import Testing

/// FC-1 follow-up (fuzz catalog, 2026-11-01): a pinned dock that takes no tabs (Home's before its `allow_tabs`, or one a
/// person closed to tabs) refused every terminal tab made in it (`dock-column-pinned`). Most terminal creators in the app
/// do not go through `TabLifecycle.newTerminal`: config commands, the account and provider login openers, Duplicate Tab
/// and the page openers call `PaneController.newTerminalTab` on the pane directly, and Tab Group's New Tab, agent
/// handlers and Agent Teams send `new-tab` themselves. cmux-tui opens such a tab in a new column right of the dock (one
/// rule for every client), so a terminal made in Home's closed dock by any of them opens beside it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct HomeClosedDockTerminalCreatorsTests {
    private static func flag(_ home: WorkspaceModel, _ dock: PaneModel) -> DockSnapshot? {
        home.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(dock.handle) }?.dock
    }

    @Test func aTerminalTabMadeDirectlyInHomesClosedDockOpensBesideIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let dock = try #require(HomeSplitKeysTests.panes(home).first)
            try await PasswordManagerRouteTests.until({ Self.flag(home, dock)?.allowsTabs == true }, report: {
                "Home's dock: \(String(describing: Self.flag(home, dock)))"
            })
            let screen = try #require(home.screens.first { $0.panes.contains { $0 === dock } }?.resourceID)
            let pane = try #require(dock.resourceID)
            try await connection.setColumnAllowsTabs(false, screen: screen, pane: pane)
            try await PasswordManagerRouteTests.until({ Self.flag(home, dock).map { $0.isPinned && !$0.allowsTabs } == true }, report: {
                "Home's dock did not close to tabs: \(String(describing: Self.flag(home, dock)))"
            })
            let controller = try #require(services.paneController(for: dock))

            // A config command's or a login opener's terminal: `newTerminalTab` on the dock's own controller.
            let work = services.registry.capturingWork { controller.newTerminalTab(cwd: NSHomeDirectory()) }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "the terminal made in Home's closed dock failed: \(failures)")
            try await PasswordManagerRouteTests.until({
                let panes = HomeSplitKeysTests.panes(home)
                return panes.count == 2 && panes.first === dock && dock.tabs.count == 1
                    && panes.last?.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) } == true
            }, report: {
                "Home's dock holds \(dock.tabs.map { "\($0.kind)" }), \(HomeSplitKeysTests.panes(home).count) pane(s); failures \(failures)"
            })
        }
    }
}
