internal import Foundation

extension ControlCommandCoordinator {
    /// Handles the remote-workspace status mutations used by indexed devbox
    /// agents. Parsing and reply shaping stay on the socket worker; the
    /// mutation itself uses the same ordered sidebar bus as the v1 commands.
    nonisolated func handleSidebarStatusV2(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        switch request.method {
        case "sidebar.set_status":
            return sidebarSetStatusV2(request.params, context: context)
        case "sidebar.clear_status":
            return sidebarClearStatusV2(request.params, context: context)
        default:
            return nil
        }
    }

    private nonisolated func sidebarSetStatusV2(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let workspaceID = string(params, "workspace_id").flatMap(UUID.init(uuidString:)) else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing status key", data: nil)
        }
        guard let value = string(params, "value") else {
            return .err(code: "invalid_params", message: "Missing status value", data: nil)
        }

        let priority: Int
        switch params["priority"] {
        case nil, .null?:
            priority = 0
        case .int(let raw)?:
            priority = max(-9999, min(9999, Int(clamping: raw)))
        case .string(let raw)?:
            guard let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .err(code: "invalid_params", message: "Invalid status priority", data: nil)
            }
            priority = max(-9999, min(9999, parsed))
        default:
            return .err(code: "invalid_params", message: "Invalid status priority", data: nil)
        }

        let format: ControlSidebarMetadataFormat
        if let rawFormat = string(params, "format") {
            guard let parsed = ControlSidebarMetadataFormat(rawValue: rawFormat) else {
                return .err(code: "invalid_params", message: "Invalid status format", data: nil)
            }
            format = parsed
        } else {
            format = .plain
        }

        let url: URL?
        if let rawURL = string(params, "url") {
            guard let parsed = URL(string: rawURL),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .err(code: "invalid_params", message: "Invalid status URL", data: nil)
            }
            url = parsed
        } else {
            url = nil
        }

        guard let context else {
            return .err(code: "unavailable", message: "Sidebar status service unavailable", data: nil)
        }
        context.controlSidebarScheduleStatusUpsert(
            target: .workspace(workspaceID),
            key: key,
            value: value,
            icon: string(params, "icon"),
            color: string(params, "color"),
            url: url,
            priority: priority,
            format: format,
            panelID: nil,
            pid: nil
        )
        return sidebarStatusMutationResult(workspaceID: workspaceID, key: key)
    }

    private nonisolated func sidebarClearStatusV2(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let workspaceID = string(params, "workspace_id").flatMap(UUID.init(uuidString:)) else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing status key", data: nil)
        }
        guard let context else {
            return .err(code: "unavailable", message: "Sidebar status service unavailable", data: nil)
        }
        context.controlSidebarScheduleStatusClear(
            target: .workspace(workspaceID),
            key: key,
            panelID: nil
        )
        return sidebarStatusMutationResult(workspaceID: workspaceID, key: key)
    }

    private nonisolated func sidebarStatusMutationResult(
        workspaceID: UUID,
        key: String
    ) -> ControlCallResult {
        .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "key": .string(key),
        ]))
    }
}
