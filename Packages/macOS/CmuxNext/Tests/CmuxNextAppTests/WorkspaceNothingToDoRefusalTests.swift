import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Workspace actions that cannot act say why, and the ones that can act on their target do
/// (unimpl-audit-actions.md rows 28, 29, 31, 32, 42): Close Workspaces Above/Below/Others
/// and Close Other Workspaces in Group with nothing to close, Next Workspace in Group alone in
/// its group, New Workspace in Group reporting its create, and Rename Workspace on another window's
/// row.
/// Runs the app's registry against a same-tree cmux-tui daemon, as the menus and the CLI reach it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceNothingToDoRefusalTests {
    private static func workspaceTarget(_ id: String) -> ActionTargetRef { ActionTargetRef(kind: .workspace, id: id) }

    /// The active window's only ordinary workspace (Home never closes, so it is not counted).
    private static func onlyWorkspace(_ services: AppServices) throws -> WorkspaceModel {
        let window = try #require(services.windows.active)
        let rows = services.windows.registry.members(of: window.state.id).compactMap(services.workspace(id:)).filter { !HomeRules.isHome($0) }
        try #require(rows.count == 1, "the window starts with \(rows.count) workspaces")
        return try #require(rows.first)
    }

    /// The menu row's reason for `target`, and a confirmed CLI run's refusal.
    private static func outcome(_ id: ActionID, _ target: ActionTargetRef, _ services: AppServices) -> (menu: String?, cli: String?) {
        let menu = ActionTargetReasons.reason(for: id, invocation: ActionInvocation(target: target), in: services.registry)
        let cli = services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: ActionInvocation(target: target, origin: .cli).confirmed())
        }
        return (menu, cli)
    }

    /// What the window's sidebar lists, for a wait that times out.
    static func sidebarReport(_ workspace: WorkspaceModel, _ services: AppServices) -> String {
        let context = AppActionContext(services: services)
        guard let sidebar = try? WorkspaceVerbHandlers.sidebar(showing: workspace, context) else { return "no sidebar" }
        let personal = context.personalGroupID(of: workspace)
        let shown = personal.map { sidebar.model.group(sidebar.model.groupID(personal: $0.rawValue))?.workspaces.map(\.id.rawValue) ?? [] }
        let nodes = sidebar.model.sections.map { section in
            section.nodes.map { node -> String in
                switch node {
                case .workspace(let row): "ws:\(row.id.rawValue)"
                case .group(let group): "group:\(group.id)[\(group.workspaces.map(\.id.rawValue).joined(separator: ","))]"
                case .item(let item): "item:\(item.id)"
                }
            }.joined(separator: " ")
        }
        return "workspace \(workspace.id) personal \(String(describing: personal)) shown \(String(describing: shown)) sections \(nodes)"
    }

    /// Puts `workspace` alone in a new personal group (the home session's state; the sidebar is not asked).
    static func personalGroup(of workspace: WorkspaceModel, _ services: AppServices) async throws -> WorkspaceGroupID {
        let context = AppActionContext(services: services)
        try await PinnedPageTests.until({ services.machines.local.store.personal.isLoaded }, report: { "personal state never loaded" })
        _ = services.registry.perform("newWorkspaceGroup", invocation: ActionInvocation(target: workspaceTarget(workspace.id),
                                                                                         arguments: ["name": .string("Solo")], origin: .cli))
        try await PinnedPageTests.until({ context.personalGroupID(of: workspace) != nil },
                                        report: { "groups \(services.machines.local.store.personal.groups.map(\.id))" })
        return try #require(context.personalGroupID(of: workspace))
    }

    /// Runs `body` on an app whose launch workspace is alone in a group the sidebar shows.
    static func withGroupedApp(_ body: (AppServices, WorkspaceModel, WorkspaceGroupID) async throws -> Void) async throws {
        let launch = try await GroupedAppLaunch.start()
        let result: Result<Void, any Error>
        do {
            let context = AppActionContext(services: launch.services)
            // What the group verbs read: the group of the row in its window's sidebar.
            try await PinnedPageTests.until({ (try? WorkspaceVerbHandlers.group(of: launch.workspace, context)) != nil },
                                            report: { sidebarReport(launch.workspace, launch.services) })
            result = .success(try await body(launch.services, launch.workspace, launch.group))
        } catch { result = .failure(error) }
        await launch.stop()
        try result.get()
    }

    @Test func closeWorkspacesAboveBelowAndOthersOnALoneRowSayThereAreNone() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try Self.onlyWorkspace(services)
            for id: ActionID in ["palette.closeWorkspacesBelow", "palette.closeWorkspacesAbove", "palette.closeOtherWorkspaces"] {
                let (menu, cli) = Self.outcome(id, Self.workspaceTarget(workspace.id), services)
                #expect(menu != nil, "\(id) on the only row is enabled and closes nothing")
                #expect(cli != nil && cli == menu, "\(id): a CLI run reports \(cli ?? "success") instead of the row's reason")
            }
            #expect(services.workspace(id: workspace.id) != nil, "the workspace closed")
        }
    }

    @Test func aWorkspaceAloneInItsGroupHasNoOtherToCloseOrStepTo() async throws {
        try await Self.withGroupedApp { services, workspace, _ in
            let (menu, cli) = Self.outcome("workspace.closeOthersInGroup", Self.workspaceTarget(workspace.id), services)
            #expect(menu != nil, "Close Other Workspaces in Group on a one-member group is enabled and closes nothing")
            #expect(cli != nil && cli == menu, "a CLI run reports \(cli ?? "success") instead of the row's reason")
            for id: ActionID in ["nextSidebarTabInGroup", "prevSidebarTabInGroup"] {
                let step = services.registry.capturingRefusal {
                    _ = services.registry.perform(id, invocation: ActionInvocation(target: Self.workspaceTarget(workspace.id), origin: .cli))
                }
                #expect(step != nil, "\(id) alone in its group reports success and goes nowhere")
            }
        }
    }

    /// The CLI's run answers after the create (`action.run` awaits tracked work), so a failed
    /// create is reported instead of a success.
    @Test func newWorkspaceInGroupIsAwaitedByTheCLI() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let group = try await Self.personalGroup(of: try Self.onlyWorkspace(services), services)
            let context = AppActionContext(services: services)
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("workspaceGroup.newWorkspace", invocation: ActionInvocation(
                        target: ActionTargetRef(kind: .workspaceGroup, id: group.rawValue), origin: .cli))
                }
            }
            #expect(refusal == nil, "New Workspace in Group refused: \(refusal ?? "")")
            #expect(!work.isEmpty, "the create is not tracked: the CLI answers before it and never sees a failure")
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "the create failed: \(failures)")
            try await PinnedPageTests.until({ context.workspaces(inPersonalGroup: group).count == 2 },
                                            report: { "members \(context.workspaces(inPersonalGroup: group).map(\.id))" })
        }
    }

    /// `cmux workspace new-on-machine --machine <id>` answers with the workspace it made: the CLI's
    /// run tracks the create (`action.run` lists it in `created`; it answered `created: []` before
    /// the create had even started) and its `result` names the workspace's public id, its name and
    /// its machine.
    @Test func newWorkspaceOnMachineAnswersWithTheWorkspaceItMade() async throws {
        try await PinnedPageTests.withApp { services, _ in
            var results: [ActionResultWork] = []
            let refusal = services.registry.capturingRefusal {
                results = services.registry.capturingRun {
                    _ = services.registry.perform("workspace.newOnMachine", invocation: ActionInvocation(
                        arguments: ["machine": .string(MachineRegistry.localID)], origin: .cli))
                }.results
            }
            #expect(refusal == nil, "New Workspace on Machine refused: \(refusal ?? "")")
            let result = try #require(results.first, "the create is not tracked: action.run answers before it with created: []")
            let fields = try await result.value.get()
            #expect(fields["machine_id"] == .string(MachineRegistry.localID), "\(fields)")
            guard case .string(let id)? = fields["workspace_id"] else { Issue.record("no workspace_id: \(fields)"); return }
            #expect(id.hasPrefix("ws_"), "not the public id: \(id)")
            let workspace = try #require(services.machines.local.store.workspace(resourceID: ResourceID(rawValue: id)), "\(id) is not listed")
            #expect(fields["name"] == .string(workspace.displayName), "\(fields)")
        }
    }

    /// Rename Workspace with no name edits the row where it is listed: another window's sidebar.
    @Test func renameWorkspaceEditsTheRowInTheWindowThatListsIt() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let other = services.windows.newWindow()
            try await PinnedPageTests.until({
                services.windows.controller(for: other) != nil && !services.windows.registry.members(of: other).isEmpty
            }, within: .seconds(60), report: { "windows \(services.windows.controllers.map(\.state.id))" })
            let active = try #require(services.windows.active)
            let elsewhere = try #require(services.windows.controllers.first { $0 !== active }, "one window only")
            let workspaceID = try #require(services.windows.registry.members(of: elsewhere.state.id).first)
            try await PinnedPageTests.until({ elsewhere.sidebar.model.workspace(SidebarWorkspaceID(workspaceID)) != nil },
                                            report: { "rows \(elsewhere.sidebar.model.selectableWorkspaces.map(\.id))" })
            let refusal = services.registry.capturingRefusal {
                _ = services.registry.perform("renameWorkspace", invocation: ActionInvocation(target: Self.workspaceTarget(workspaceID), origin: .user))
            }
            #expect(refusal == nil, "Rename Workspace refused: \(refusal ?? "")")
            try await PinnedPageTests.until({ elsewhere.sidebar.container.sidebarView.list.inlineRename.isActive },
                                            within: .seconds(5), report: { "the other window's row never opened its name field" })
            #expect(!active.sidebar.container.sidebarView.list.inlineRename.isActive, "the active window started a rename")
        }
    }
}
