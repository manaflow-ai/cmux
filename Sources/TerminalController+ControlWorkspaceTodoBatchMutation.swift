import CmuxControlSocket
import CmuxWorkspaces
import Foundation

/// Batch workspace-todo mutation witnesses, kept separate so the primary
/// control-context conformance remains below the Swift file-length threshold.
@MainActor
extension TerminalController {
    func controlWorkspaceTodoSet(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        items: [ControlWorkspaceTodoSetItemParam]
    ) -> ControlWorkspaceTodoSetResolution {
        controlWorkspaceTodoBatchMutation(
            routing: routing,
            workspaceID: workspaceID,
            items: items
        ) { workspace, replacements in
            workspace.replaceChecklist(with: replacements)
        }
    }

    func controlWorkspaceTodoReconcile(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        ownerID: String,
        items: [ControlWorkspaceTodoSetItemParam]
    ) -> ControlWorkspaceTodoSetResolution {
        controlWorkspaceTodoBatchMutation(
            routing: routing,
            workspaceID: workspaceID,
            items: items
        ) { workspace, replacements in
            workspace.reconcileChecklist(ownerID: ownerID, with: replacements)
        }
    }

    private func controlWorkspaceTodoBatchMutation(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        items: [ControlWorkspaceTodoSetItemParam],
        mutation: (
            Workspace,
            [WorkspaceChecklistReplacementItem]
        ) -> Result<[WorkspaceChecklistItem], WorkspaceChecklistReplaceError>
    ) -> ControlWorkspaceTodoSetResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            let parsed = workspaceTodoReplacementItems(items)
            if let error = parsed.error { return error }
            switch mutation(workspace, parsed.items) {
            case .failure(.emptyText(let index)):
                return .emptyText(index: index)
            case .failure(.duplicateId(let index)):
                return .duplicateId(index: index)
            case .failure(.tooManyItems(let count)):
                return .tooManyItems(count: count)
            case .success:
                WorkspaceTodoFeature.markUsed()
                return .resolved(
                    windowID: AppDelegate.shared?.windowId(for: tabManager),
                    checklist: todoChecklistSnapshot(for: workspace)
                )
            }
        }
    }

    /// Parses every raw state/origin before mutation so malformed batches
    /// cannot partially update the checklist.
    private func workspaceTodoReplacementItems(
        _ items: [ControlWorkspaceTodoSetItemParam]
    ) -> (
        items: [WorkspaceChecklistReplacementItem],
        error: ControlWorkspaceTodoSetResolution?
    ) {
        var replacements: [WorkspaceChecklistReplacementItem] = []
        replacements.reserveCapacity(items.count)
        for item in items {
            var state: WorkspaceChecklistItem.State?
            if let stateRaw = item.stateRaw {
                guard let parsed = WorkspaceChecklistItem.State(rawValue: stateRaw) else {
                    return ([], .invalidState(stateRaw))
                }
                state = parsed
            }
            var origin: WorkspaceChecklistItem.Origin?
            if let originRaw = item.originRaw {
                guard let parsed = WorkspaceChecklistItem.Origin(rawValue: originRaw) else {
                    return ([], .invalidOrigin(originRaw))
                }
                origin = parsed
            }
            replacements.append(WorkspaceChecklistReplacementItem(
                id: item.id,
                text: item.text,
                state: state,
                origin: origin
            ))
        }
        return (replacements, nil)
    }
}
