import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// FC-1 (fuzz catalog, 2026-11-01): about 6 s after launch, a script's New Terminal Tab (`newSurface`, the bench's
/// `action.run`) aimed at Home's focused dock answered "new-tab: the daemon refused the new tab" in 4 of 5 bench
/// launches, while Ctrl-` (a person's key, `ChatColumnPlacement.openTool`) opened a terminal 20 of 20 times. Home's dock
/// was pinned but did not take tabs yet (`allow_tabs` off): `HomeDockOpens.opensBeside` said "no move" for it, so the
/// tab went into the dock, and cmux-tui refuses every tab there (`ensure_pane_takes_tabs`, `dock-column-pinned`).
/// Home's dock opens nothing in itself, whoever asks (home-chief-pane.md H1, H5): a new terminal aimed at it opens in a
/// column right of it, whether the dock takes tabs or not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct HomeClosedDockNewTerminalTests {
    private static func flag(_ home: WorkspaceModel, _ dock: PaneModel) -> DockSnapshot? {
        home.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(dock.handle) }?.dock
    }

    @Test(arguments: [ActionOrigin.script, .cli])
    func aNewTerminalAimedAtHomesDockThatTakesNoTabsOpensBesideIt(_ origin: ActionOrigin) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let dock = try #require(HomeSplitKeysTests.panes(home).first)
            try await PasswordManagerRouteTests.until({ Self.flag(home, dock)?.allowsTabs == true }, report: {
                "Home's dock: \(String(describing: Self.flag(home, dock)))"
            })
            // The dock as it is between its pin and its `allow_tabs` (or as a person closed it): pinned, taking no tabs.
            let screen = try #require(home.screens.first { $0.panes.contains { $0 === dock } }?.resourceID)
            let pane = try #require(dock.resourceID)
            try await connection.setColumnAllowsTabs(false, screen: screen, pane: pane)
            try await PasswordManagerRouteTests.until({ Self.flag(home, dock).map { $0.isPinned && !$0.allowsTabs } == true }, report: {
                "Home's dock did not close to tabs: \(String(describing: Self.flag(home, dock)))"
            })

            let work = services.registry.capturingWork {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(
                    target: ActionTargetRef(kind: .pane, id: dock.id), arguments: [:], origin: origin))
            }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "\(origin): the new terminal aimed at Home's closed dock failed: \(failures)")
            try await PasswordManagerRouteTests.until({
                let panes = HomeSplitKeysTests.panes(home)
                return panes.count == 2 && panes.first === dock && dock.tabs.count == 1
                    && panes.last?.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) } == true
            }, report: {
                "\(origin): Home's dock holds \(dock.tabs.map { "\($0.kind)" }), \(HomeSplitKeysTests.panes(home).count) pane(s); "
                    + "failures \(failures)"
            })
        }
    }
}
