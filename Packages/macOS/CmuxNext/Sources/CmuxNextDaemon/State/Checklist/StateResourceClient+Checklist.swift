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
        var params: [String: JSONValue] = ["workspace": .string(workspace.rawValue), "text": .string(text), "origin": .string("user")]
        if let index { params["index"] = .number(Double(max(0, index))) }
        try await stateMutation("workspace_checklist.add", params)
    }

    /// Changes an item (`workspace_checklist.update`): only the fields given.
    public func updateChecklistItem(_ workspace: ResourceID, item: String, text: String? = nil,
                                    state: WorkspaceChecklistItem.State? = nil, index: Int? = nil,
                                    attachments: [WorkspaceChecklistAttachment]? = nil) async throws {
        try await stateMutation("workspace_checklist.update", Self.checklistUpdateParams(
            workspace, item: item, text: text, state: state, index: index, attachments: attachments))
    }

    /// Removes an item (`workspace_checklist.remove`).
    public func removeChecklistItem(_ workspace: ResourceID, item: String) async throws {
        try await stateMutation("workspace_checklist.remove", ["workspace": .string(workspace.rawValue), "item": .string(item)])
    }

    /// The `workspace_checklist.update` parameters: the item and each field that changes.
    /// `attachments` is the item's whole list; one without an id is new.
    public static func checklistUpdateParams(_ workspace: ResourceID, item: String, text: String? = nil,
                                             state: WorkspaceChecklistItem.State? = nil, index: Int? = nil,
                                             attachments: [WorkspaceChecklistAttachment]? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["workspace": .string(workspace.rawValue), "item": .string(item)]
        if let text { params["text"] = .string(text) }
        if let state { params["state"] = .string(state.rawValue) }
        if let index { params["index"] = .number(Double(max(0, index))) }
        if let attachments { params["attachments"] = .array(attachments.map(\.json)) }
        return params
    }
}
