import CmuxCore
import Foundation

/// Owns Mac layout revisions and applies authenticated, workspace-scoped edits.
@MainActor
final class DeviceWorkspaceLayoutHost {
    nonisolated static let eventTopic = "device.workspace.layout.changed"
    nonisolated static let externalGeometryKey = "deviceLayoutExternal"
    nonisolated static let layoutGeometryKey = "deviceLayoutSnapshot"

    private struct Receipt {
        let params: Data
        let result: MobileHostRPCResult
    }

    private let capture: @MainActor (UUID) -> DeviceWorkspaceLayoutNode?
    private let apply: @MainActor (UUID, DeviceWorkspaceLayoutNode) throws -> Void
    private let createTerminal: @MainActor (UUID, UUID, SurfaceSplitDirection?) throws -> UUID?
    private let publish: @MainActor (DeviceWorkspaceLayoutSnapshot) -> Void
    private let notificationCenter: NotificationCenter
    // Registration is main-actor-only; deinit exclusively removes this opaque
    // Foundation token through NotificationCenter's thread-safe cleanup API.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var snapshots: [UUID: DeviceWorkspaceLayoutSnapshot] = [:]
    private var receipts: [String: Receipt] = [:]
    private var receiptOrder: [String] = []

    init(
        capture: @escaping @MainActor (UUID) -> DeviceWorkspaceLayoutNode?,
        apply: @escaping @MainActor (UUID, DeviceWorkspaceLayoutNode) throws -> Void,
        createTerminal: @escaping @MainActor (UUID, UUID, SurfaceSplitDirection?) throws -> UUID?,
        publish: @escaping @MainActor (DeviceWorkspaceLayoutSnapshot) -> Void,
        notificationCenter: NotificationCenter = .default
    ) {
        self.capture = capture
        self.apply = apply
        self.createTerminal = createTerminal
        self.publish = publish
        self.notificationCenter = notificationCenter
        // Geometry notifications are the existing native layout event seam.
        // Capture only the Sendable ID before hopping out of its callback.
        observer = notificationCenter.addObserver(forName: .workspacePaneGeometryDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.snapshots[id] != nil else { return }
                _ = self.snapshot(for: id)
            }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    func snapshot(for workspaceID: UUID) -> DeviceWorkspaceLayoutSnapshot? {
        guard let layout = capture(workspaceID), (try? layout.validatedSurfaceIDs()) != nil else {
            return nil
        }
        let previous = snapshots[workspaceID]
        let unchanged = previous?.layout.hasSameArrangement(as: layout) == true
        let revision = unchanged ? previous?.revision ?? UUID().uuidString : UUID().uuidString
        let sequence = (previous?.sequence ?? 0) + (unchanged ? 0 : 1)
        let snapshot = DeviceWorkspaceLayoutSnapshot(workspaceID: workspaceID.uuidString, layout: layout,
            revision: revision, sequence: sequence)
        snapshots[workspaceID] = snapshot
        if !unchanged { publish(snapshot) }
        return snapshot
    }

    /// This handler is installed only after an incoming Mac peer is authorized.
    func handle(_ request: MobileHostRPCRequest) -> MobileHostRPCResult? {
        let methods = ["device.workspace.layout", "device.workspace.layout.apply", "device.workspace.terminal.create"]
        guard methods.contains(request.method) else { return nil }
        guard let rawID = request.params["workspace_id"] as? String, let workspaceID = UUID(uuidString: rawID) else {
            return failure("invalid_params", "Expected workspace_id")
        }
        do {
            if request.method == "device.workspace.layout" {
                guard let snapshot = snapshot(for: workspaceID) else { return failure("not_found", "Workspace layout unavailable") }
                return .ok(try payload(snapshot))
            }
            let allowed: Set<String> = request.method == "device.workspace.layout.apply"
                ? ["workspace_id", "request_id", "base_revision", "layout"]
                : ["workspace_id", "request_id", "source_surface_id", "direction"]
            guard Set(request.params.keys).isSubset(of: allowed),
                  let requestID = request.params["request_id"] as? String, !requestID.isEmpty, requestID.count <= 128 else {
                return failure("invalid_params", "Expected a bounded request_id and supported parameters")
            }
            let key = request.method + ":" + workspaceID.uuidString + ":" + requestID
            let encoded = try JSONSerialization.data(withJSONObject: request.params, options: [.sortedKeys])
            if let receipt = receipts[key] {
                return receipt.params == encoded ? receipt.result : failure("invalid_params", "Request ID was reused for another edit")
            }
            guard let current = snapshot(for: workspaceID) else { return failure("not_found", "Workspace layout unavailable") }
            let result: MobileHostRPCResult
            if request.method == "device.workspace.layout.apply" {
                guard request.params["base_revision"] as? String == current.revision else {
                    return .failure(MobileHostRPCError(code: "layout_conflict", message: "Workspace layout changed", data: try payload(current)))
                }
                guard let object = request.params["layout"] as? [String: Any] else {
                    return failure("invalid_params", "Expected layout")
                }
                let next = try JSONDecoder().decode(DeviceWorkspaceLayoutNode.self,
                    from: JSONSerialization.data(withJSONObject: object))
                guard Set(try next.validatedSurfaceIDs()) == Set(try current.layout.validatedSurfaceIDs()) else {
                    return failure("invalid_params", "Layout must contain exactly this workspace's terminals")
                }
                try apply(workspaceID, next)
                guard let accepted = snapshot(for: workspaceID) else { return failure("not_found", "Workspace closed during edit") }
                result = .ok(try payload(accepted))
            } else {
                guard let rawSurface = request.params["source_surface_id"] as? String,
                      let surfaceID = UUID(uuidString: rawSurface),
                      try current.layout.validatedSurfaceIDs().contains(surfaceID.uuidString) else {
                    return failure("invalid_params", "Source terminal must belong to this workspace")
                }
                let direction: SurfaceSplitDirection?
                if let raw = request.params["direction"] as? String {
                    guard let parsed = SurfaceSplitDirection(rawValue: raw) else { return failure("invalid_params", "Invalid split direction") }
                    direction = parsed
                } else {
                    direction = nil
                }
                guard let terminalID = try createTerminal(workspaceID, surfaceID, direction) else {
                    return failure("unavailable", "Could not create a terminal in this workspace")
                }
                var response: [String: Any] = ["created_terminal_id": terminalID.uuidString, "workspace_id": workspaceID.uuidString]
                if let accepted = snapshot(for: workspaceID) { response["snapshot"] = try payload(accepted) }
                result = .ok(response)
            }
            receipts[key] = Receipt(params: encoded, result: result)
            receiptOrder.append(key)
            if receiptOrder.count > 128 { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
            return result
        } catch {
            return failure("invalid_params", "Could not apply this workspace layout")
        }
    }

    private func payload(_ snapshot: DeviceWorkspaceLayoutSnapshot) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
    }

    private func failure(_ code: String, _ message: String) -> MobileHostRPCResult {
        .failure(MobileHostRPCError(code: code, message: message))
    }
}
