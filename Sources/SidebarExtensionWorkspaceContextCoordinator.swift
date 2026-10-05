@_spi(CmuxHostTransport) import CmuxExtensionKit
import Foundation

/// Applies SDK context requests to the exact native workspace; no extension copy is authoritative.
@MainActor
struct SidebarExtensionWorkspaceContextCoordinator {
    let tabManager: TabManager

    func perform(_ action: CmuxSidebarAction) -> CmuxSidebarActionResult? {
        switch action {
        case .mutateWorkspaceContext(let id, let revision, let mutation):
            return edit(id) { try $0.workspaceContext.mutate(expectedRevision: revision, mutation: mutation) }
        case .storeWorkspaceContextProposal(let id, let revision, let proposal):
            return edit(id) { try $0.workspaceContext.storeProposal(expectedRevision: revision, proposal: proposal) }
        case .applyWorkspaceContextProposal(let id, let revision, let proposalID, let tagIDs, let acceptTitle, let acceptSummary):
            return edit(id) { workspace in
                let change = try workspace.workspaceContext.prepareProposal(expectedRevision: revision, proposalID: proposalID, tagIDs: tagIDs, acceptTitle: acceptTitle, acceptSummary: acceptSummary)
                let previousDisplayTitle = workspace.title
                var titleUndo: WorkspaceContextModel.TitleUndo?
                if let title = change.suggestedTitle, workspace.customTitle != title {
                    // A daemon-owned cloud name is an asynchronous request. Do not
                    // claim an atomic local acceptance or submit a request we cannot undo.
                    guard permitsSynchronousTitleEdit(workspace) else { throw ContextDispatchError.titleUnavailable }
                    let previousCustomTitle = workspace.customTitle
                    let previousSource = workspace.effectiveCustomTitleSource?.rawValue
                    guard tabManager.setCustomTitle(tabId: id, title: title), workspace.customTitle == title else { throw ContextDispatchError.titleUnavailable }
                    titleUndo = WorkspaceContextModel.TitleUndo(previousCustomTitle: previousCustomTitle, previousSource: previousSource, appliedCustomTitle: title)
                }
                workspace.workspaceContext.commitProposal(change, previousDisplayTitle: previousDisplayTitle, titleUndo: titleUndo)
            }
        case .undoWorkspaceContext(let id, let revision):
            return edit(id) { workspace in
                let undo = try workspace.workspaceContext.pendingUndo(expectedRevision: revision)
                if let title = undo.title, workspace.customTitle == title.appliedCustomTitle {
                    guard permitsSynchronousTitleEdit(workspace) else { throw ContextDispatchError.titleUnavailable }
                    let previousSource = title.previousSource.flatMap(Workspace.CustomTitleSource.init(rawValue:)) ?? .user
                    // Undo is an explicit user title choice. Restoring an old
                    // automatic title must not let a later analyzer replace it.
                    let source: Workspace.CustomTitleSource = previousSource == .auto ? .user : previousSource
                    guard tabManager.setCustomTitle(tabId: id, title: title.previousCustomTitle, source: source), workspace.customTitle == title.previousCustomTitle else { throw ContextDispatchError.titleUnavailable }
                }
                workspace.workspaceContext.commitUndo(undo, revision: revision)
            }
        default:
            return nil
        }
    }

    private func permitsSynchronousTitleEdit(_ workspace: Workspace) -> Bool {
        workspace.cloudVMBinding == nil && !workspace.panels.keys.contains { panelID in
            workspace.cloudProjectedResource(forPanel: panelID)?.id.machine.cloudMachineID != nil
        }
    }

    private enum ContextDispatchError: Error { case titleUnavailable }

    private func edit(_ id: UUID, perform: (Workspace) throws -> Void) -> CmuxSidebarActionResult {
        guard let workspace = tabManager.tabs.first(where: { $0.id == id }) else {
            return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
        }
        do {
            try perform(workspace)
            return .accepted
        } catch WorkspaceContextModel.MutationError.revisionConflict {
            return .rejected(String(localized: "sidebar.extensions.context.revisionConflict", defaultValue: "This workspace changed. Refresh before editing its context."), reason: .revisionConflict)
        } catch WorkspaceContextModel.MutationError.proposalNotFound {
            return .rejected(String(localized: "sidebar.extensions.context.proposalNotFound", defaultValue: "This analysis is no longer available. Refresh the workspace."))
        } catch WorkspaceContextModel.MutationError.undoUnavailable {
            return .rejected(String(localized: "sidebar.extensions.context.undoUnavailable", defaultValue: "There is no context change to undo."))
        } catch ContextDispatchError.titleUnavailable {
            return .rejected(String(localized: "sidebar.extensions.context.titleUnavailable", defaultValue: "The proposed title could not be applied. The context was retained."))
        } catch {
            return .rejected(String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
        }
    }
}
