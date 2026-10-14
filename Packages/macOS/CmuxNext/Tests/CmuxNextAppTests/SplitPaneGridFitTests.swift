import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A fresh split layout's terminals render the grid their views fit (cx-yt7rt). The restore
/// journey's rj-split seeded four terminals in nested splits and a second tab in the first pane;
/// before the first quit the first pane drew a 664 pt view with 48 rows (46 fit) and the lower
/// panes 33 rows where 32 fit, so the shell had rows below the bottom edge until a relaunch.
/// The same layout here, made the way a script makes it, on the real daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitPaneGridFitTests {
    @Test func splitPanesAndASecondTabRenderTheGridTheirViewsFit() async throws {
        try await Self.withApp { services in
            let controller = try #require(services.windows.active)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await Self.until({ Self.shown(controller, workspace: id).count == 1 && Self.allLive(controller) },
                                 report: { Self.describe(controller) })
            let a = try #require(Self.shown(controller, workspace: id).first)
            // rj-split: A | B, B over C, C | D, made by a script (no person's split rules).
            let b = try await Self.split(a, "splitRight", services, controller, workspace: id)
            let c = try await Self.split(b, "splitDown", services, controller, workspace: id)
            _ = try await Self.split(c, "splitRight", services, controller, workspace: id)
            // A second tab in A (its strip appears), A's first tab still selected.
            let tabs = a.orderedIDs.count
            #expect(services.registry.perform("newSurface", invocation: Self.at(a)))
            try await Self.until({ a.orderedIDs.count == tabs + 1 }, report: { Self.describe(controller) })
            // Every terminal on screen ends up rendering what its view fits.
            try await Self.until({ Self.allLive(controller) && Self.mismatched(controller).isEmpty },
                                 report: { "grid != fit: \(Self.mismatched(controller))\n\(Self.describe(controller))" })
        }
    }

    private static func at(_ pane: PaneController) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.pane.id), origin: .cli)
    }

    private static func split(_ pane: PaneController, _ action: ActionID, _ services: AppServices,
                              _ controller: WindowController, workspace: String) async throws -> PaneController {
        let before = Set(shown(controller, workspace: workspace).map(\.layoutPaneID))
        #expect(services.registry.perform(action, invocation: at(pane)))
        try await until({ shown(controller, workspace: workspace).count == before.count + 1 && allLive(controller) },
                        report: { describe(controller) })
        return try #require(shown(controller, workspace: workspace).first { !before.contains($0.layoutPaneID) })
    }

    /// The panes of `workspace` while the window shows it.
    private static func shown(_ controller: WindowController, workspace: String) -> [PaneController] {
        guard let content = controller.workspaceContent, content.workspace.id == workspace else { return [] }
        return Array(content.panes.values)
    }

    private static func panes(_ controller: WindowController) -> [PaneController] {
        controller.workspaceContent.map { Array($0.panes.values) } ?? []
    }

    /// Every pane shows a terminal with a grid.
    private static func allLive(_ controller: WindowController) -> Bool {
        let panes = panes(controller)
        return !panes.isEmpty && panes.allSatisfy { $0.surfaceStatus.terminal?.grid != nil && $0.surfaceStatus.terminal?.fitGrid != nil }
    }

    /// Panes whose terminal is not drawn at the pane's content height (a legacy scroller may
    /// take width), or renders a grid other
    /// than the one its view fits.
    private static func mismatched(_ controller: WindowController) -> [String] {
        panes(controller).compactMap { pane in
            let status = pane.surfaceStatus
            guard let terminal = status.terminal, let grid = terminal.grid, let fit = terminal.fitGrid else { return nil }
            if abs(terminal.viewSize.height - status.contentSize.height) > 1 {
                return "\(pane.paneKey): surface \(Int(terminal.viewSize.width))x\(Int(terminal.viewSize.height)) in a pane drawing \(Int(status.contentSize.width))x\(Int(status.contentSize.height))"
            }
            guard grid != fit else { return nil }
            return "\(pane.paneKey): \(grid.columns)x\(grid.rows) in a view fitting \(fit.columns)x\(fit.rows)"
        }
    }

    private static func describe(_ controller: WindowController) -> String {
        panes(controller).map { pane in
            let status = pane.surfaceStatus
            let terminal = status.terminal
            let grid = terminal?.grid.map { "\($0.columns)x\($0.rows)" } ?? "-"
            let fit = terminal?.fitGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"
            let view = terminal.map { "\(Int($0.viewSize.width))x\(Int($0.viewSize.height))" } ?? "-"
            return "\(pane.paneKey) tabs=\(pane.orderedIDs.count) presence=\(status.presence) content=\(Int(status.contentSize.width))x\(Int(status.contentSize.height)) view=\(view) grid=\(grid) fit=\(fit)"
        }.joined(separator: "\n")
    }

    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(20),
                              report: () -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out: \(report())", sourceLocation: sourceLocation)
    }

    /// The app's services on a fresh same-tree daemon with its window laid out on screen.
    private static func withApp(_ body: (AppServices) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-splitgrid-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-splitgrid-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let result: Result<Void, any Error>
        do {
            try await until({ services.windows.active?.window != nil && services.daemon.connection != nil }, within: .seconds(90))
            result = .success(try await body(services))
        } catch { result = .failure(error) }
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        try result.get()
    }
}
