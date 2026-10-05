@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Local-only classification bridge. No command or arbitrary filesystem path is accepted.
    @MainActor
    func workspaceOrganizationResponse(_ request: ControlRequest) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        let id = request.id?.foundationObject
        guard let manager = v2ResolveTabManager(params: params) else {
            return v2Error(id: id, code: "not_found", message: String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
        }
        let workspaceIDs: [UUID]?
        if let value = params["workspace_id"] {
            guard params["workspace_ids"] == nil, let text = value as? String,
                  let uuid = UUID(uuidString: text), manager.tabs.contains(where: { $0.id == uuid }) else {
                return v2Error(id: id, code: "invalid_params", message: String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
            }
            workspaceIDs = [uuid]
        } else if let values = params["workspace_ids"] {
            guard let strings = values as? [String], !strings.isEmpty, strings.count <= 256 else {
                return v2Error(id: id, code: "invalid_params", message: String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
            }
            let ids = strings.compactMap(UUID.init(uuidString:))
            guard ids.count == strings.count, Set(ids).count == ids.count else {
                return v2Error(id: id, code: "invalid_params", message: String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
            }
            workspaceIDs = ids
        } else { workspaceIDs = nil }
        if request.method == "workspace.context.export" {
            do {
                let data = try await manager.sidebarOrganizationCoordinator.export(tabManager: manager, workspaceIDs: workspaceIDs)
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                return v2Ok(id: id, result: result)
            } catch { return v2Error(id: id, code: "classification_unavailable", message: String(localized: "sidebar.extensions.organization.unavailable", defaultValue: "Analysis is unavailable. Check the local classification engine and Python 3.11, then retry.")) }
        }
        guard let rawID = params["export_id"] as? String, let exportID = UUID(uuidString: rawID),
              let review = params["review"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: review), data.count <= 2 * 1024 * 1024 else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
        }
        let result = await manager.sidebarOrganizationCoordinator.analyze(tabManager: manager, workspaceIDs: workspaceIDs, exportID: exportID, review: data)
        return result.accepted ? v2Ok(id: id, result: ["accepted": true, "proposals_retained": true])
            : v2Error(id: id, code: result.rejectionReason?.rawValue ?? "rejected", message: result.message ?? String(localized: "sidebar.extensions.context.invalidPayload", defaultValue: "The context request is invalid or exceeds its limits."))
    }
}
