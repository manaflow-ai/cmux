import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// A terminal tab opened with New Terminal Tab (Ctrl-`, `newSurface`: the optimistic stand-in path,
/// ctrl-backtick-instant) follows its window's resizes like any other terminal (felt 1e, Lawrence
/// 2026-10-29: "the terminal doesnt resize properly"). The P0 journey second-window-resize read a
/// 110x40 grid in a 656x408 view from v2.2.5-opt on: Ghostty's fitted grid stayed at the size the
/// tab first showed at, while the view's bounds followed the window, and no grid report went out.
/// A Cmd-D split's terminal in the same window followed (journey diagnosis, /work/tmp/resize-1e).
/// The product boundary: the real daemon, the action, the window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TerminalNewTabResizeTests {
    @Test func aNewTerminalTabFollowsItsWindowsResize() async throws {
        try await Self.withApp { services in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await Self.until({ Self.shown(controller, workspace: id).count == 1 && Self.live(services, Self.shown(controller, workspace: id)) },
                                 report: { Self.describe(services, controller) })
            let pane = try #require(Self.shown(controller, workspace: id).first)
            let first = pane.currentTabKey

            // New Terminal Tab in the shown pane, as Ctrl-` runs it.
            #expect(services.registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.pane.id), origin: .user)))
            try await Self.until({
                guard let key = pane.currentTabKey, key != first, !ProvisionalTab.isProvisional(key) else { return false }
                return Self.live(services, [pane]) && Self.unfitted(services, [pane]).isEmpty
            }, report: { "the new tab never showed fitted: " + Self.describe(services, controller) })

            // The window gets smaller, as a person's drag or a window_place leaves it.
            let tall = window.frame
            window.setFrame(NSRect(x: tall.minX, y: tall.minY + 150, width: tall.width - 240, height: tall.height - 150), display: true)
            try await Self.until({ Self.unfitted(services, [pane]).isEmpty },
                                 report: { "after the resize: \(Self.unfitted(services, [pane]))\n" + Self.describe(services, controller) })
        }
    }

    /// The panes whose shown terminal's Ghostty grid is not the grid its view's size fits, or whose
    /// owner grid differs from that fit.
    private static func unfitted(_ services: AppServices, _ panes: [PaneController]) -> [String] {
        panes.compactMap { pane in
            guard let key = pane.currentTabKey, let surface = services.cache.existingTerminal(key)?.session.surfaceView,
                  let ghostty = surface.surface else { return "\(pane.paneKey): no surface" }
            let pixels = surface.convertToBacking(surface.bounds.size)
            var columns: UInt16 = 0, rows: UInt16 = 0
            guard ghostty_surface_fit_grid(ghostty, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows) else {
                return "\(pane.paneKey): no whole cell fits \(surface.bounds.size)"
            }
            let want = TerminalGridSize(columns: Int(columns), rows: Int(rows))
            let status = pane.surfaceStatus.terminal
            guard status?.fitGrid == want, status?.grid == want else {
                return "\(pane.paneKey) \(key): view \(Int(surface.bounds.width))x\(Int(surface.bounds.height)) fits \(want.columns)x\(want.rows),"
                    + " surface fit \(status?.fitGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"), grid \(status?.grid.map { "\($0.columns)x\($0.rows)" } ?? "-")"
            }
            return nil
        }
    }

    private static func live(_ services: AppServices, _ panes: [PaneController]) -> Bool {
        !panes.isEmpty && panes.allSatisfy { $0.surfaceStatus.terminal?.grid != nil && $0.surfaceStatus.terminal?.fitGrid != nil }
    }

    private static func shown(_ controller: WindowController, workspace: String) -> [PaneController] {
        if controller.workspaceContent?.workspace.id != workspace {
            controller.services.windows.show(workspaceID: workspace, in: controller.state)
        }
        guard let content = controller.workspaceContent, content.workspace.id == workspace else { return [] }
        return Array(content.panes.values)
    }

    /// Each pane's shown terminal and where its surface stands in the visibility tree (the size work
    /// of a surface that is not shown waits on its window node).
    private static func describe(_ services: AppServices, _ controller: WindowController) -> String {
        let panes = controller.workspaceContent.map { Array($0.panes.values) } ?? []
        let frame = controller.window.map { "window \(Int($0.frame.width))x\(Int($0.frame.height))\n" } ?? ""
        return frame + panes.map { pane in
            let key = pane.currentTabKey ?? "nil"
            guard let surface = services.cache.existingTerminal(key)?.session.surfaceView else { return "\(pane.paneKey) tab \(key): no terminal" }
            let status = pane.surfaceStatus.terminal
            let node = surface.visibilityNode, parent = node.parent
            return "\(pane.paneKey) tab \(key) tabs=\(pane.orderedIDs.map(\.rawValue)) view=\(Int(surface.bounds.width))x\(Int(surface.bounds.height))"
                + " grid=\(status?.grid.map { "\($0.columns)x\($0.rows)" } ?? "-") fit=\(status?.fitGrid.map { "\($0.columns)x\($0.rows)" } ?? "-")"
                + " shown=\(surface.isShown) window-node own=\(surface.windowNode.own) effective=\(surface.windowNode.effective) deferred=\(surface.windowNode.deferredCount)"
                + " surface-node own=\(node.own) effective=\(node.effective)"
                + " tab-node \(parent?.name ?? "nil") own=\(parent.map { "\($0.own)" } ?? "-") effective=\(parent.map { "\($0.effective)" } ?? "-")"
                + " under \(parent?.parent?.name ?? "nil")"
        }.joined(separator: "\n")
    }

    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(30),
                              report: () -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out: \(report())", sourceLocation: sourceLocation)
    }

    /// The app's services on a fresh same-tree daemon with its window laid out on screen (as
    /// `SplitPaneGridFitTests.withApp`).
    private static func withApp(_ body: (AppServices) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-newtabfit-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cn-newtabfit-\(UUID().uuidString.prefix(8).lowercased())",
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
