import Foundation
import CmuxControlSocket
import CmuxNestedTopology
import CmuxSettings

/// Control-socket handlers for nested topology read + capability-gated focus (PR4/PR5).
///
/// Runs on the socket worker (`nested.topology.list`, `nested.node.focus`).
/// Nested nodes are never injected into Bonsplit / Workspace. Focus never
/// synthesizes keystrokes when the provider capability is absent.
extension TerminalController {
    /// `nested.topology.list` — project attached nested topologies.
    ///
    /// Optional params: `host_surface_id` (UUID), `host_workspace_id` (string).
    /// Default tree (`system.tree` without `include_nested`) is unchanged.
    nonisolated func v2NestedTopologyList(id: Any?, params: [String: Any]) -> String {
        guard NestedTopologyController.isEnabled else {
            return v2Error(
                id: id,
                code: "disabled",
                message: String(
                    localized: "socket.nestedTopology.disabled",
                    defaultValue: "nested topology beta is disabled"
                )
            )
        }

        let hostSurfaceID = Self.nestedTopologyUUID(params["host_surface_id"])
        if params["host_surface_id"] != nil && hostSurfaceID == nil {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.nestedTopology.invalidHostSurfaceID",
                    defaultValue: "Missing or invalid host_surface_id"
                )
            )
        }
        let hostWorkspaceID = (params["host_workspace_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceFilter = (hostWorkspaceID?.isEmpty == false) ? hostWorkspaceID : nil

        return v2VmCall(id: id, timeoutSeconds: 15) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.nestedTopologyController })
            else {
                throw NestedTopologySocketError.appNotReady
            }
            let result = await controller.listAttachments(
                hostStableSurfaceID: hostSurfaceID,
                hostWorkspaceID: workspaceFilter
            )
            guard let payload = NestedTopologyControlSocketPayload().foundationObject(for: result) else {
                throw NestedTopologySocketError.encodeFailed
            }
            return payload
        }
    }

    /// `nested.node.focus` — capability-gated focus of one virtual nested node.
    ///
    /// Required params:
    /// - `host_surface_id` (UUID)
    /// - `node_id` (structured compound NestedNodeID object)
    ///
    /// Optional params:
    /// - `expected_attachment_id` (UUID)
    /// - `expected_provider_instance_id` (string)
    ///
    /// Resolves host surface + attachment generation atomically before send.
    /// Does not activate cmux workspaces/panes and never invents optimistic topology.
    nonisolated func v2NestedNodeFocus(id: Any?, params: [String: Any]) -> String {
        guard NestedTopologyController.isEnabled else {
            return v2Error(
                id: id,
                code: "disabled",
                message: String(
                    localized: "socket.nestedTopology.disabled",
                    defaultValue: "nested topology beta is disabled"
                )
            )
        }

        let hostSurfaceID = Self.nestedTopologyUUID(params["host_surface_id"])
        guard let hostSurfaceID else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.nestedTopology.invalidHostSurfaceID",
                    defaultValue: "Missing or invalid host_surface_id"
                )
            )
        }

        guard let nodeID = NestedTopologyControlSocketPayload().decodeNodeID(from: params["node_id"]) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.nestedTopology.invalidNodeID",
                    defaultValue: "Missing or invalid node_id"
                )
            )
        }

        var expectedAttachmentID: UUID?
        if params["expected_attachment_id"] != nil {
            expectedAttachmentID = Self.nestedTopologyUUID(params["expected_attachment_id"])
            if expectedAttachmentID == nil {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.nestedTopology.invalidAttachmentID",
                        defaultValue: "Missing or invalid expected_attachment_id"
                    )
                )
            }
        }

        var expectedProviderInstanceID: NestedProviderInstanceID?
        if let raw = params["expected_provider_instance_id"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.nestedTopology.invalidProviderInstanceID",
                        defaultValue: "Missing or invalid expected_provider_instance_id"
                    )
                )
            }
            expectedProviderInstanceID = NestedProviderInstanceID(rawValue: trimmed)
        } else if params["expected_provider_instance_id"] != nil {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.nestedTopology.invalidProviderInstanceID",
                    defaultValue: "Missing or invalid expected_provider_instance_id"
                )
            )
        }

        let requestID = Self.nestedTopologyRequestIDString(id)
        let focusRequest = NestedNodeFocusRequest(
            hostStableSurfaceID: hostSurfaceID,
            nodeID: nodeID,
            expectedAttachmentID: expectedAttachmentID,
            expectedProviderInstanceID: expectedProviderInstanceID,
            authorization: .authenticatedControlSocket(requestID: requestID)
        )

        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.nestedTopologyController })
            else {
                return .err(
                    code: "app_not_ready",
                    message: NestedTopologySocketError.appNotReady.description,
                    data: nil
                )
            }
            do {
                let result = try await controller.focusNode(focusRequest)
                guard let payload = NestedTopologyControlSocketPayload().foundationObject(for: result) else {
                    return .err(
                        code: "encode_failed",
                        message: NestedTopologySocketError.encodeFailed.description,
                        data: nil
                    )
                }
                return .ok(payload)
            } catch let error as NestedAttachmentError {
                return .err(
                    code: error.socketErrorCode,
                    message: error.errorDescription
                        ?? String(
                            localized: "socket.nestedTopology.focusFailed",
                            defaultValue: "Nested focus failed"
                        ),
                    data: ["error_class": error.telemetryErrorClass]
                )
            } catch {
                return .err(
                    code: "provider_error",
                    message: String(
                        localized: "socket.nestedTopology.focusFailed",
                        defaultValue: "Nested focus failed"
                    ),
                    data: ["error_class": "provider_error"]
                )
            }
        }
    }

    /// Whether `system.tree` requested nested descendants.
    nonisolated static func nestedTopologyIncludeNestedRequested(_ params: [String: Any]) -> Bool {
        NestedTopologyControlSocketPayload().includeNestedRequested(params)
    }

    private nonisolated static func nestedTopologyUUID(_ value: Any?) -> UUID? {
        if let uuid = value as? UUID { return uuid }
        if let string = value as? String {
            return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private nonisolated static func nestedTopologyRequestIDString(_ id: Any?) -> String {
        if let string = id as? String { return string }
        if let number = id as? NSNumber { return number.stringValue }
        if let int = id as? Int { return String(int) }
        return "nested-focus"
    }
}

/// Errors surfaced through `v2VmCall` for nested topology reads.
enum NestedTopologySocketError: Error, CustomStringConvertible {
    case appNotReady
    case encodeFailed

    var description: String {
        switch self {
        case .appNotReady:
            return "app not ready"
        case .encodeFailed:
            return "failed to encode nested topology"
        }
    }
}
