internal import Foundation

/// The simulator domain (`simulator.open` / `simulator.close`): the pane
/// half of the `cmux simulator` namespace. `simulator.list` blocks on
/// `simctl` and therefore runs on the app-side socket-worker lane, not here.
extension ControlCommandCoordinator {
    /// The guidance line returned whenever a simulator verb refuses because
    /// the `simulator.beta.enabled` flag is off.
    static let simulatorFeatureDisabledMessage =
        "The simulator surface is disabled. Enable \"iOS Simulator Panes\" in Settings → Beta Features (simulator.beta.enabled)."

    /// Dispatches the simulator methods this coordinator owns; returns `nil`
    /// for anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a simulator method.
    func handleSimulator(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "simulator.open":
            return simulatorOpen(request.params)
        case "simulator.close":
            return simulatorClose(request.params)
        default:
            return nil
        }
    }

    /// `simulator.open` — open a simulator pane for a device (name or UDID)
    /// in the target workspace. Booting/attaching happens asynchronously in
    /// the pane; the reply carries the created pane's handles immediately.
    private func simulatorOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let deviceQuery = string(params, "device") else {
            return .err(
                code: "invalid_params",
                message: "Missing device (a simulator device name or UDID)",
                data: nil
            )
        }
        let resolution = context?.controlSimulatorOpen(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            deviceQuery: deviceQuery,
            requestedFocus: bool(params, "focus") ?? false
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .featureDisabled:
            return .err(code: "feature_disabled", message: Self.simulatorFeatureDisabledMessage, data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .openFailed:
            return .err(code: "internal_error", message: "Failed to open simulator pane", data: nil)
        case .opened(let windowID, let workspaceID, let paneID, let surfaceID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": orNull(paneID?.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    /// `simulator.close` — close a simulator pane. With no `surface_id`, the
    /// workspace's only simulator pane closes; several panes require an
    /// explicit handle.
    private func simulatorClose(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlSimulatorClose(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            surfaceID: uuid(params, "surface_id")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .featureDisabled:
            return .err(code: "feature_disabled", message: Self.simulatorFeatureDisabledMessage, data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound:
            return .err(code: "not_found", message: "No simulator pane in the target workspace", data: nil)
        case .ambiguous(let count):
            return .err(
                code: "invalid_params",
                message: "Workspace has \(count) simulator panes; pass --surface to pick one",
                data: .object(["count": .int(Int64(count))])
            )
        case .closed(let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }
}
