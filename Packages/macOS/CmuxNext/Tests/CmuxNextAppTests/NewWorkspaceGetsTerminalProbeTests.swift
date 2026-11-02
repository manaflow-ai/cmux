import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// SHORTCUT-F9 probe (NEVER MERGE): on display worker cmuxs-Mac-mini-4 (step 151622cdd9f4) a workspace made with
/// `createWorkspace(WorkspaceSpawn(cwd:name:))` and no command showed only the New Tab page: its terminal never came.
/// This makes the same workspace on the feat tip and reports, every 0.5 s for 20 s, each pane's selected tab kind and
/// the store's tabs of the workspace, then requires a terminal (`.pty`) tab.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewWorkspaceGetsTerminalProbeTests {
    @Test func aWorkspaceWithNoCommandGetsItsTerminal() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            try await PasswordManagerRouteTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            try #require(controller.window).orderFrontRegardless()
            let folder = FileManager.default.temporaryDirectory.appending(path: "sf-f9-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let workspace = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: folder.path, name: "sf-f9"),
                                                                       into: controller.state.id)
            services.windows.show(workspaceID: workspace, in: controller.state)
            @MainActor func describe() -> String {
                let panes = (controller.content?.panes.values.map { pane in
                    "\(pane.paneKey):" + (pane.selectedTab.map { "\($0.kind)" } ?? "none") + "/\(pane.pane.tabs.count)"
                } ?? []).sorted().joined(separator: ",")
                let store = services.machines.local.store.workspaces.first { $0.id.rawValue == workspace || "\($0.key?.rawValue ?? "")" == workspace }
                let tabs = store.map { ws in ws.screens.flatMap { $0.panes.flatMap { $0.tabs.map { "\($0.kind)" } } }.joined(separator: ",") } ?? "no store workspace"
                return "shows \(controller.state.workspaceID ?? "nil"); panes [\(panes)]; store tabs [\(tabs)]"
            }
            var log: [String] = []
            let start = ContinuousClock.now
            var found = false
            while ContinuousClock.now - start < .seconds(20) {
                let line = describe()
                if log.last != line { log.append("\(ContinuousClock.now - start): \(line)") }
                if controller.state.workspaceID == workspace,
                   controller.content?.panes.values.contains(where: { $0.selectedTab?.kind == .pty }) == true { found = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            print("SF-F9-PROBE " + (found ? "TERMINAL" : "NO-TERMINAL") + " " + log.joined(separator: " | "))
            #expect(found, "no terminal in 20 s: \(log.joined(separator: " | "))")
        }
    }
}
