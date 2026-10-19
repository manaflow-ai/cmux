public import CmuxMobileShellModel
internal import Foundation

extension MobileCoreRPCClient {
    /// Applies one workspace todo mutation on the paired Mac.
    /// - Parameters:
    ///   - mutation: The mutation to apply through the shared Mac todo path.
    ///   - workspaceID: The Mac-local workspace identifier.
    /// - Throws: A transport or RPC error when the mutation fails.
    public func mutateTodo(
        _ mutation: MobileTodoMutation,
        workspaceID: String
    ) async throws {
        let method: String
        var params: [String: Any] = ["workspace_id": workspaceID]
        switch mutation {
        case .add(let text):
            method = "mobile.todo.add"
            params["text"] = text
        case .setState(let itemID, let state):
            method = "mobile.todo.set_state"
            params["id"] = itemID
            params["state"] = state.rawValue
        case .edit(let itemID, let text):
            method = "mobile.todo.edit"
            params["id"] = itemID
            params["text"] = text
        case .move(let itemID, let toIndex):
            method = "mobile.todo.move"
            params["id"] = itemID
            params["to_index"] = toIndex
        case .remove(let itemID):
            method = "mobile.todo.remove"
            params["id"] = itemID
        case .openOnMac:
            method = "mobile.todo.open"
            params["focus"] = true
        case .setStatus(let status):
            method = "mobile.status.set"
            params["status"] = status?.rawValue ?? "auto"
        case .cycleStatus:
            method = "mobile.status.cycle"
        }
        let request = try Self.requestData(method: method, params: params)
        _ = try await sendRequest(request)
    }
}
