import Foundation

extension Workspace {
    private nonisolated static let remoteRelayWorkspaceIDKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
    ]

    private nonisolated static let remoteRelaySurfaceIDKeys: Set<String> = [
        "panel_id",
        "surface_id",
        "preferred_panel_id",
        "preferred_surface_id",
        "target_panel_id",
        "target_surface_id",
        "created_panel_id",
        "created_surface_id",
        "before_panel_id",
        "before_surface_id",
        "after_panel_id",
        "after_surface_id",
    ]

    private nonisolated static let remoteRelayAmbiguousIDKeys: Set<String> = [
        "tab_id",
    ]

    private nonisolated static let remoteRelayWorkspaceIDArrayKeys: Set<String> = [
        "workspace_ids",
    ]

    private nonisolated static let remoteRelaySurfaceIDArrayKeys: Set<String> = [
        "panel_ids",
        "surface_ids",
    ]

    private nonisolated static let remoteRelayAmbiguousIDArrayKeys: Set<String> = [
        "tab_ids",
        "tab_id_groups",
    ]

    nonisolated static func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        remoteWorkspaceID: UUID? = nil
    ) -> Data {
        rewriteRemoteRelayCommandLineAndExtractMethod(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases,
            remoteWorkspaceID: remoteWorkspaceID
        ).commandLine
    }

    nonisolated static func rewriteRemoteRelayCommandLineAndExtractMethod(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        remoteWorkspaceID: UUID? = nil
    ) -> (commandLine: Data, method: String?) {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty || remoteWorkspaceID != nil,
              let line = String(data: commandLine, encoding: .utf8) else {
            return (commandLine, nil)
        }
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let requestData = trimmedLine.data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return (commandLine, nil)
        }
        let method = request["method"] as? String

        var didRewrite = false
        if var params = request["params"] as? [String: Any] {
            params = Self.remappedRemoteRelayValue(
                params,
                key: nil,
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases,
                didRewrite: &didRewrite
            ) as? [String: Any] ?? params
            if method == "surface.resume.set",
               let remoteWorkspaceID {
                params["_cmux_remote_workspace_id"] = remoteWorkspaceID.uuidString
                didRewrite = true
            }
            request["params"] = params
        }

        guard didRewrite,
              JSONSerialization.isValidJSONObject(request),
              let rewritten = try? JSONSerialization.data(withJSONObject: request, options: []) else {
            return (commandLine, method)
        }
        if commandLine.last == 0x0A {
            return (rewritten + Data([0x0A]), method)
        }
        return (rewritten, method)
    }

    private nonisolated static func remappedRemoteRelayValue(
        _ value: Any,
        key: String?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        didRewrite: inout Bool
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            for (childKey, childValue) in dictionary {
                result[childKey] = remappedRemoteRelayValue(
                    childValue,
                    key: childKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases,
                    didRewrite: &didRewrite
                )
            }
            return result
        }

        if let array = value as? [Any] {
            let elementKey: String?
            if let key, remoteRelayWorkspaceIDArrayKeys.contains(key) {
                elementKey = "workspace_id"
            } else if let key, remoteRelaySurfaceIDArrayKeys.contains(key) {
                elementKey = "surface_id"
            } else if let key, remoteRelayAmbiguousIDArrayKeys.contains(key) {
                elementKey = "tab_id"
            } else if let key, remoteRelayWorkspaceIDKeys.contains(key)
                        || remoteRelaySurfaceIDKeys.contains(key)
                        || remoteRelayAmbiguousIDKeys.contains(key) {
                elementKey = key
            } else {
                elementKey = nil
            }
            return array.map {
                remappedRemoteRelayValue(
                    $0,
                    key: elementKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases,
                    didRewrite: &didRewrite
                )
            }
        }

        guard let id = value as? String else {
            return value
        }

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmedID) else {
            return value
        }

        guard let key else {
            return value
        }
        if remoteRelaySurfaceIDKeys.contains(key),
           let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if remoteRelayWorkspaceIDKeys.contains(key),
           let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        guard remoteRelayAmbiguousIDKeys.contains(key) else {
            return value
        }

        if let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }

        return value
    }
}
