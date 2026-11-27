import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Split terminals that were hidden while their window got shorter and their pane got a second
/// tab claim the grid their views fit once shown again (cx-yt7rt). The restore journey's rj-split
/// read 55x48 in a 664 pt view: the window lost about 25 pt while rj-split was hidden, and the
/// journey read the grids in the frame the workspace came back, about 50 ms before the claim's
/// echo. The product boundary here: the real daemon, a script's splits and tab, and the window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitPaneGridFitTests {
    @Test func splitPanesShownAgainRenderTheGridTheirViewsFit() async throws {
        try await Self.withApp { services in
            let controller = try #require(services.windows.active)
            // The journey's window width, so A | B has room (a pane is at least ~200 points wide).
            try #require(controller.window).setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await Self.until({ Self.shown(controller, workspace: id).count == 1 && Self.allLive(controller) },
                                 report: { Self.describe(controller) })
            let a = try #require(Self.shown(controller, workspace: id).first)
            // rj-split's first split, A | B, made by a script (no person's split rules). Its
            // nested down splits need more height than a CI Mac's short display gives a window.
            _ = try await Self.split(a, "splitRight", services, controller, workspace: id)
            // Every terminal on screen ends up rendering what its view fits.
            try await Self.settled(controller, workspace: id)

            // While another workspace is shown (the journey seeds the next one), A gets a second
            // tab (its strip appears; its first tab stays selected) and the window gets shorter.
            // Shown again, the split workspace's terminals follow both.
            let other = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await Self.until({ Self.shown(controller, workspace: other).count == 1 && Self.allLive(controller) },
                                 report: { "want \(other) (split \(id)): " + Self.describe(controller) })
            // The daemon's tab: A's strip is suspended while its workspace is parked (0964d17bd5c) and
            // maps the new tab once the workspace is shown again.
            let tabs = a.pane.tabs.count
            #expect(services.registry.perform("newSurface", invocation: Self.at(a)))
            try await Self.until({ a.pane.tabs.count == tabs + 1 }, report: { Self.describe(controller) })
            let window = try #require(controller.window)
            let tall = window.frame
            window.setFrame(NSRect(x: tall.minX, y: tall.minY + 60, width: tall.width, height: tall.height - 60), display: true)
            try await Task.sleep(for: .milliseconds(500))
            services.windows.show(workspaceID: id, in: controller.state)
            try await Self.until({ Self.shown(controller, workspace: id).count == 2 && Self.allLive(controller) },
                                 report: { Self.describe(controller) })
            try await Self.settled(controller, workspace: id)
        }
    }

    /// Every terminal of `workspace` ends up rendering what its view fits.
    private static func settled(_ controller: WindowController, workspace: String,
                                sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until({ !shown(controller, workspace: workspace).isEmpty && allLive(controller) && mismatched(controller).isEmpty },
                        report: { "grid != fit: \(mismatched(controller))\n\(describe(controller))" }, sourceLocation: sourceLocation)
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

    /// The panes of `workspace`, shown in the window. A fresh session's Home (an agent tab on some
    /// Macs) can take the window back while the test waits, so each poll shows the workspace again.
    private static func shown(_ controller: WindowController, workspace: String) -> [PaneController] {
        if controller.workspaceContent?.workspace.id != workspace {
            controller.services.windows.show(workspaceID: workspace, in: controller.state)
        }
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

    /// Panes whose terminal surface is not as tall as the pane draws it (a legacy scroller may
    /// take width), or that renders a grid other than the one its surface fits.
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
        let shows = "shows \(controller.state.workspaceID ?? "nil"), content \(controller.workspaceContent?.workspace.id ?? "nil")"
            + " (parked \(controller.workspaceContent?.isParked == true), draws nothing \(controller.workspaceContent?.drawsNothing == true)), page \(String(describing: controller.state.page))"
        let frame = (controller.window.map { "window \(Int($0.frame.width))x\(Int($0.frame.height)) " } ?? "") + shows + "\n"
        return frame + panes(controller).map { pane in
            let status = pane.surfaceStatus
            let terminal = status.terminal
            let grid = terminal?.grid.map { "\($0.columns)x\($0.rows)" } ?? "-"
            let fit = terminal?.fitGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"
            let view = terminal.map { "\(Int($0.viewSize.width))x\(Int($0.viewSize.height))" } ?? "-"
            return "\(pane.paneKey) suspended=\(pane.isSuspended) kind=\(status.kind) tabs=\(pane.orderedIDs.count) presence=\(status.presence) content=\(Int(status.contentSize.width))x\(Int(status.contentSize.height)) view=\(view) grid=\(grid) fit=\(fit)"
        }.joined(separator: "\n")
    }

    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(60),
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
            // Launch is over: its first workspace (a New Tab page) was made and shown. Before
            // that, `restore()` could land it over the test's workspace mid-body.
            try await until({ services.windows.active?.window != nil && services.daemon.connection != nil && !services.windows.registry.isLaunching },
                            within: .seconds(90))
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
