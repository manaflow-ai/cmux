import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// cmux.json `workspaceGroups.byCwd` in the app (unimpl-audit-actions.md row 22): a group's entry
/// is found by its anchor's folder; its color and icon draw on the group's header, its rows join
/// the header menu, and Edit Group Config… opens the file at that entry, making it when missing.
/// Runs against a same-tree cmux-tui daemon, with the settings in a temporary file.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceGroupConfigAppTests {
    /// `body` with the app's settings in a temporary cmux.json holding `text`, and the launch
    /// workspace with a terminal in a known folder, in a personal group of its own.
    private static func withGroupedWorkspace(
        config text: (String) -> String,
        _ body: (AppServices, WorkspaceModel, WorkspaceGroupID, URL) async throws -> Void
    ) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let folder = FileManager.default.temporaryDirectory.appending(path: "cn-group-config-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let workspace = try #require(services.daemon.store.workspaces.first { !HomeRules.isHome($0) })
            let pane = try #require(workspace.screens.first?.panes.first?.handle)
            var options = SpawnOptions()
            options.cwd = folder.path
            _ = try await connection.newTab(in: pane, options: options)
            try await PinnedPageTests.until({ WorkspaceGroupConfigLook.directory(of: workspace) != nil },
                                            report: { "no terminal reports a folder: \(workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { $0.cwd ?? "-" })" })
            let anchor = try #require(WorkspaceGroupConfigLook.directory(of: workspace))
            let url = folder.appending(path: "cmux.json")
            try Data(text(anchor).utf8).write(to: url)
            let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            services.settings = settings
            await settings.reload()
            // What a parallel run does: another suite binds its own AppServices meanwhile, whose first sidebarLayout
            // read sets the process-wide SidebarDocStore.current.
            let other = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(other)
            let group = try await WorkspaceNothingToDoRefusalTests.personalGroup(of: workspace, services)
            try await body(services, workspace, group, url)
        }
    }

    private static func sidebarGroup(_ group: WorkspaceGroupID, _ workspace: WorkspaceModel) -> SidebarGroup {
        SidebarGroup(id: CmuxNextSidebar.GroupID(group.rawValue), name: "Solo", color: .grey,
                     workspaces: [SidebarWorkspace(id: WorkspaceID(workspace.id), title: workspace.name)])
    }

    @Test func aGroupsEntryDrawsItsColorAndIconAndAddsItsMenuRows() async throws {
        try await Self.withGroupedWorkspace(config: { anchor in """
            {"workspaceGroups": {"byCwd": {"\(anchor)": {"color": "#7A4FD8", "icon": "ladybug.fill",
              "contextMenu": [{"action": "newWorkspace", "title": "Make One"}]}}}}
            """ }) { services, workspace, group, _ in
            let config = try #require(services.settings?.snapshot.workspaceGroups)
            #expect(!config.byCwd.isEmpty, "the file's entry was not read")
            let look = WorkspaceGroupConfigLook(config: config, machines: services.machines)
            let section = SidebarRowSection(kind: .machine(SidebarMachine(id: MachineID("local"), name: "Mac", kind: .local)),
                                            nodes: [.group(Self.sidebarGroup(group, workspace))])
            guard case .group(let drawn)? = look.applying(to: [section]).first?.nodes.first else {
                Issue.record("the group is gone")
                return
            }
            #expect(drawn.tint == GroupTint(wire: "#7A4FD8"), "the entry's color does not draw")
            #expect(drawn.icon == WorkspaceIcon.parse("ladybug.fill"), "the entry's icon does not draw")
            let target = ActionTargetRef(kind: .workspaceGroup, id: group.rawValue)
            let rows = look.menuItems(for: Self.sidebarGroup(group, workspace), target: target, registry: services.registry)
            #expect(rows.map(\.title) == ["Make One"])
            #expect(rows.first.flatMap { ActionRegistry.menuRun(of: $0) }?.id == "workspaceGroup.newWorkspace")
            #expect(rows.first.flatMap { ActionRegistry.menuRun(of: $0) }?.target == target)
        }
    }

    @Test func editGroupConfigMakesTheGroupsEntryWhenMissing() async throws {
        try await Self.withGroupedWorkspace(config: { _ in "{\n  // mine\n}\n" }) { services, workspace, group, url in
            let anchor = try #require(WorkspaceGroupConfigLook.directory(of: workspace))
            let failures = try await Self.runEditConfig(group, services)
            #expect(failures.isEmpty, "Edit Group Config failed: \(failures)")
            let source = try String(contentsOf: url, encoding: .utf8)
            let key = WorkspaceGroupConfig.key(for: anchor)
            #expect(JSONC.position(of: WorkspaceGroupConfig.byCwdPath + [key], in: source) != nil, "no entry for \(key) in:\n\(source)")
            #expect(source.contains("// mine"), "the file's comment is gone")
        }
    }

    @Test func editGroupConfigKeepsAMatchingEntry() async throws {
        try await Self.withGroupedWorkspace(config: { anchor in
            #"{"workspaceGroups": {"byCwd": {"\#((anchor as NSString).deletingLastPathComponent)/*": {"icon": "leaf.fill"}}}}"#
        }) { services, _, group, url in
            let before = try String(contentsOf: url, encoding: .utf8)
            let failures = try await Self.runEditConfig(group, services)
            #expect(failures.isEmpty, "Edit Group Config failed: \(failures)")
            #expect(try String(contentsOf: url, encoding: .utf8) == before, "a matching entry exists: nothing is added")
        }
    }

    /// Runs Edit Group Config from the CLI on `group` and returns its failures.
    private static func runEditConfig(_ group: WorkspaceGroupID, _ services: AppServices) async throws -> [String] {
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork {
                _ = services.registry.perform("workspaceGroup.editConfig", invocation: ActionInvocation(
                    target: ActionTargetRef(kind: .workspaceGroup, id: group.rawValue), origin: .cli))
            }
        }
        var failures = refusal.map { [$0] } ?? []
        if work.isEmpty, refusal == nil { failures.append("no work was tracked") }
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        return failures
    }
}
