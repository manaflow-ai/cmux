import CmuxNextIPC
import Foundation

/// The workspace checklist operations (`workspace_checklist.*`, `workspace-checklist-v1`). Each
/// change answers with the whole checklist, which `session.events` also delivers to the mirror.
extension StateResourceClient {
    /// Adds an item (`workspace_checklist.add`) at `index`, last by default.
    /// - Parameters:
    ///   - workspace: The workspace's public id.
    ///   - text: The item's text; the daemon trims it and refuses an empty one.
    ///   - index: Where the item goes; nil puts it last.
    public func addChecklistItem(_ workspace: ResourceID, text: String, index: Int? = nil) async throws {
        try await stateMutation(Self.checklistAddRequest(workspace, text: text, index: index))
    }

    /// Changes an item (`workspace_checklist.update`): only the fields given.
    public func updateChecklistItem(_ workspace: ResourceID, item: String, text: String? = nil,
                                    state: WorkspaceChecklistItem.State? = nil, index: Int? = nil,
                                    attachments: [WorkspaceChecklistAttachment]? = nil) async throws {
        try await stateMutation(Self.checklistUpdateRequest(
            workspace, item: item, text: text, state: state, index: index, attachments: attachments))
    }

    /// Removes an item (`workspace_checklist.remove`).
    public func removeChecklistItem(_ workspace: ResourceID, item: String) async throws {
        try await stateMutation(V2WorkspaceChecklistRemoveRequest(workspace: Self.selector(workspace), item: item))
    }

    /// The `workspace_checklist.add` request: the person's item (origin `user`).
    static func checklistAddRequest(_ workspace: ResourceID, text: String, index: Int?) -> V2WorkspaceChecklistAddRequest {
        V2WorkspaceChecklistAddRequest(workspace: selector(workspace), index: index.map(Self.index), origin: .user, text: text)
    }

    /// The `workspace_checklist.update` request: the item and each field that changes.
    /// `attachments` is the item's whole list; one without an id is new.
    static func checklistUpdateRequest(_ workspace: ResourceID, item: String, text: String? = nil,
                                       state: WorkspaceChecklistItem.State? = nil, index: Int? = nil,
                                       attachments: [WorkspaceChecklistAttachment]? = nil) -> V2WorkspaceChecklistUpdateRequest {
        V2WorkspaceChecklistUpdateRequest(
            workspace: selector(workspace),
            attachments: attachments.map { list in
                list.map { V2WorkspaceChecklistAttachmentInput(id: $0.id, name: $0.name, path: $0.path) }
            },
            index: index.map(Self.index), item: item,
            state: state.map { V2WorkspaceChecklistItemState(rawValue: $0.rawValue) }, text: text)
    }
}
