import Foundation

/// Identifies a Task Manager process owner decoded from a diagnostic payload.
struct CmuxTaskManagerMemoryAttribution: Sendable {
    let workspaceId: UUID?
    let workspaceRef: String?
    let paneId: UUID?
    let paneRef: String?
    let surfaceId: UUID?
    let surfaceRef: String?
    let surfaceType: String?
    let reason: String?

    init?(_ payload: [String: Any]?) {
        guard let payload else { return nil }
        self.workspaceId = Self.uuid(payload["workspace_id"])
        self.workspaceRef = CmuxTaskManagerMemoryDiagnostic.string(payload["workspace_ref"])
        self.paneId = Self.uuid(payload["pane_id"])
        self.paneRef = CmuxTaskManagerMemoryDiagnostic.string(payload["pane_ref"])
        self.surfaceId = Self.uuid(payload["surface_id"])
        self.surfaceRef = CmuxTaskManagerMemoryDiagnostic.string(payload["surface_ref"])
        self.surfaceType = CmuxTaskManagerMemoryDiagnostic.string(payload["surface_type"])
        self.reason = CmuxTaskManagerMemoryDiagnostic.string(payload["reason"])
        if workspaceId == nil,
           workspaceRef == nil,
           paneId == nil,
           paneRef == nil,
           surfaceId == nil,
           surfaceRef == nil,
           surfaceType == nil {
            return nil
        }
    }

    var localizedDescription: String {
        var parts: [String] = []
        if let workspace = workspaceRef ?? workspaceId?.uuidString {
            parts.append(String.localizedStringWithFormat(
                String(localized: "taskManager.memory.workspace", defaultValue: "Workspace %@"),
                workspace
            ))
        }
        if let pane = paneRef ?? paneId?.uuidString {
            parts.append(String.localizedStringWithFormat(
                String(localized: "taskManager.memory.pane", defaultValue: "Pane %@"),
                pane
            ))
        }
        if let surface = surfaceRef ?? surfaceId?.uuidString {
            parts.append(String.localizedStringWithFormat(
                String(localized: "taskManager.memory.surface", defaultValue: "Surface %@"),
                surface
            ))
        }
        if let reason, !reason.isEmpty {
            parts.append(String.localizedStringWithFormat(
                String(localized: "taskManager.memory.evidence", defaultValue: "Evidence: %@"),
                reason
            ))
        }
        return parts.isEmpty
            ? String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed")
            : parts.joined(separator: " / ")
    }

    private static func uuid(_ raw: Any?) -> UUID? {
        if let value = raw as? UUID {
            return value
        }
        guard let value = CmuxTaskManagerMemoryDiagnostic.string(raw) else {
            return nil
        }
        return UUID(uuidString: value)
    }
}
