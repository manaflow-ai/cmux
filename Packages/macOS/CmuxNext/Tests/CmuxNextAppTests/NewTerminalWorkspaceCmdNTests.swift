import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTabs
import Foundation
import Testing

/// #26051: with `newTerminal.opensWorkspace` (New Terminal Opens a Workspace (cmux classic)) on, a
/// person's Cmd-N opens a workspace whose terminal starts in the focused terminal's folder, as in
/// cmux classic, not the New Tab page. Off (the default), Cmd-N opens the New Tab page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTerminalWorkspaceCmdNTests {
    @Test func cmdNOpensTerminalWorkspaceInFocusedTerminalFolder() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-26051")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let directory = FileManager.default.temporaryDirectory.appending(path: "cn-26051-\(UUID().uuidString)")
            let folder = directory.appending(path: "work")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "cmux.json")
            try Data("{}".utf8).write(to: url)
            let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            #expect(settings.snapshot.newTerminalOpensWorkspace == false, "off by default")
            services.settings = settings

            @MainActor func tabs(_ id: String) -> [TabModel] {
                services.daemon.store.workspaces.first { $0.id == id }?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
            }
            @MainActor func resolved(_ path: String?) -> String? {
                path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            }
            let expected = resolved(folder.path)
            /// Cmd-N; returns the new workspace's id and tabs once it lists a tab.
            @MainActor func cmdN() async throws -> (String, [TabModel]) {
                let workspacesBefore = Set(services.daemon.store.workspaces.map(\.id))
                #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
                @MainActor func created() -> String? { services.daemon.store.workspaces.first { !workspacesBefore.contains($0.id) }?.id }
                try await PasswordManagerRouteTests.until({ created().map { !tabs($0).isEmpty } == true },
                                                          report: { "new workspace tabs: \(created().map(tabs) ?? [])" })
                let id = try #require(created())
                return (id, tabs(id))
            }

            // The default: Cmd-N opens the New Tab page, in the workspace it shows.
            let (workspace, page) = try await cmdN()
            #expect(page.contains { services.agentTabs.isNewTabPage($0.id) }, "new workspace tabs: \(page.map { "\($0.id) \($0.kind)" })")
            try await PasswordManagerRouteTests.until({ services.windows.active?.focusedPane?.workspace?.workspace.id == workspace },
                                                      report: { "focused workspace: \(services.windows.active?.focusedPane?.workspace?.workspace.id ?? "none")" })
            let pane = try #require(services.windows.active?.focusedPane)

            // The folder the person works in: a terminal tab in `folder`, selected in the focused pane.
            let before = Set(tabs(workspace).map(\.id))
            #expect(services.registry.perform("newSurface", invocation: ActionInvocation(arguments: ["cwd": .string(folder.path)], origin: .user)))
            try await PasswordManagerRouteTests.until({ tabs(workspace).contains { !before.contains($0.id) && $0.kind == .pty } },
                                                      report: { "tabs: \(tabs(workspace).map { "\($0.id) \($0.kind)" })" })
            let terminal = try #require(tabs(workspace).first { !before.contains($0.id) && $0.kind == .pty })
            try await PasswordManagerRouteTests.until({ pane.currentTabKey == terminal.id && resolved(pane.selectedTab?.cwd) == expected },
                                                      report: { "selected: \(pane.currentTabKey ?? "none") cwd: \(pane.selectedTab?.cwd ?? "none")" })

            try await settings.set(.bool(true), at: NewTerminalWorkspaceSetting.configPath)
            try await PasswordManagerRouteTests.until({ services.settings?.snapshot.newTerminalOpensWorkspace == true })

            // On: Cmd-N opens a workspace whose only tab is a terminal that starts in `folder` (its cwd may report later).
            let (opened, created) = try await cmdN()
            #expect(created.allSatisfy { $0.kind == .pty && !services.agentTabs.isNewTabPage($0.id) },
                    "new workspace tabs: \(created.map { "\($0.id) \($0.kind)" })")
            try await PasswordManagerRouteTests.until({ !tabs(opened).isEmpty && tabs(opened).allSatisfy { resolved($0.cwd) == expected } },
                                                      report: { "new workspace cwd: \(tabs(opened).map { $0.cwd ?? "none" }), expected \(expected ?? "none")" })
        }
    }
}
