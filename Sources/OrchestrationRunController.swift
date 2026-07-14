import CmuxOrchestration
import Foundation

/// Executes an `OrchestrationRunPlan`: provisions each task workspace off
/// the main actor (git worktree/clone or the template's provision script),
/// then creates the cmux workspace for it — grouped in the sidebar, never
/// focused, with the agent command delivered as typed terminal input.
///
/// This is deliberately the *actuation* half only; planning, validation, and
/// the trust gate live in `CmuxOrchestration` and the socket seam. The fleet
/// engine (#7361) will later drive richer supervision through the same plan
/// shape.
@MainActor
final class OrchestrationRunController {
    static let shared = OrchestrationRunController()

    private let provisioner = OrchestrationProvisioner()

    /// Starts one run. Creates the sidebar group synchronously (so the run
    /// response can reference it), then provisions and attaches workspaces
    /// in the background, one at a time — concurrent `git worktree add`
    /// calls on one repository would race its lock files.
    func start(plan: OrchestrationRunPlan, tabManager: TabManager) {
        try? FileManager.default.createDirectory(
            atPath: plan.workspaceRoot,
            withIntermediateDirectories: true
        )
        let groupID = tabManager.createWorkspaceGroup(
            name: plan.groupName,
            anchorWorkingDirectory: plan.workspaceRoot,
            selectAnchor: false,
            collapseSidebarSelection: false
        )
        let provisioner = self.provisioner
        Task { [weak tabManager] in
            var failures: [String] = []
            var firstWorkspaceID: UUID?
            for workspacePlan in plan.workspaces {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try provisioner.provision(workspacePlan)
                    }.value
                } catch {
                    failures.append("\(workspacePlan.title): \(String(describing: error))")
                    continue
                }
                guard let tabManager else { return }
                let workspaceID = Self.attachWorkspace(
                    from: workspacePlan,
                    groupID: groupID,
                    tabManager: tabManager
                )
                if firstWorkspaceID == nil {
                    firstWorkspaceID = workspaceID
                }
            }
            Self.notifyCompletion(plan: plan, failures: failures, workspaceID: firstWorkspaceID)
        }
    }

    /// Creates the cmux workspace for one provisioned directory. The agent
    /// command is typed input (the workspace's main process stays the login
    /// shell), delivered via `initialTerminalInput` or, when the template
    /// ships a layout, as the layout's setup command.
    private static func attachWorkspace(
        from workspacePlan: OrchestrationWorkspacePlan,
        groupID: UUID?,
        tabManager: TabManager
    ) -> UUID {
        let layoutNode = workspacePlan.layoutJSON.flatMap(decodeLayoutNode)
        let workspace = tabManager.addWorkspace(
            title: workspacePlan.title,
            workingDirectory: workspacePlan.directory,
            initialTerminalInput: layoutNode == nil ? workspacePlan.commandText + "\n" : nil,
            workspaceEnvironment: workspacePlan.env,
            inheritWorkingDirectory: false,
            select: false,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false
        )
        if let layoutNode {
            workspace.applyCustomLayout(
                layoutNode,
                baseCwd: workspacePlan.directory,
                setupCommand: workspacePlan.commandText
            )
        }
        if let groupID {
            tabManager.addWorkspaceToGroup(
                workspaceId: workspace.id,
                groupId: groupID,
                placement: .end
            )
        }
        return workspace.id
    }

    /// Accepts the three layout JSON shapes a template may ship: a full
    /// saved layout (`{"workspace": {"layout": …}}`), a workspace definition
    /// (`{"layout": …}`), or a bare layout node.
    private static func decodeLayoutNode(from json: String) -> CmuxLayoutNode? {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        if let saved = try? decoder.decode(CmuxSavedLayout.self, from: data), let node = saved.workspace.layout {
            return node
        }
        if let definition = try? decoder.decode(CmuxWorkspaceDefinition.self, from: data), let node = definition.layout {
            return node
        }
        return try? decoder.decode(CmuxLayoutNode.self, from: data)
    }

    private static func notifyCompletion(plan: OrchestrationRunPlan, failures: [String], workspaceID: UUID?) {
#if DEBUG
        cmuxDebugLog(
            "orchestration.run.finished name=\(plan.orchestrationName) run=\(plan.runID.prefix(6)) ok=\(plan.workspaces.count - failures.count) failed=\(failures.count)"
        )
#endif
        guard let store = AppDelegate.shared?.notificationStore else { return }
        let anchorWorkspaceID = workspaceID
            ?? AppDelegate.shared?.activeTabManagerForCommands()?.selectedWorkspace?.id
        guard let anchorWorkspaceID else { return }
        if failures.isEmpty {
            store.addNotification(
                tabId: anchorWorkspaceID,
                surfaceId: nil,
                title: String(localized: "orchestration.run.readyTitle", defaultValue: "Orchestration run ready"),
                subtitle: plan.groupName,
                body: String(
                    format: String(
                        localized: "orchestration.run.readyBody",
                        defaultValue: "%1$d workspace(s) provisioned and running."
                    ),
                    plan.workspaces.count
                )
            )
        } else {
            store.addNotification(
                tabId: anchorWorkspaceID,
                surfaceId: nil,
                title: String(localized: "orchestration.run.failedTitle", defaultValue: "Orchestration run had failures"),
                subtitle: plan.groupName,
                body: failures.joined(separator: "\n")
            )
        }
    }
}
