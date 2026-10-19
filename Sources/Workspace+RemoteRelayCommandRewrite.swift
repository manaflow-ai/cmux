import CmuxRemoteWorkspace
import Foundation

extension Workspace {
    // The canonical remote-relay ID key sets live in
    // `RemoteRelayCommandPolicy` (the relay package's authorization gate walks
    // the same keys); alias rewriting must see exactly the keys the policy
    // scopes, so both sides share one source of truth.
    private nonisolated static var remoteRelayWorkspaceIDKeys: Set<String> {
        RemoteRelayCommandPolicy.workspaceIDKeys
    }

    private nonisolated static var remoteRelaySurfaceIDKeys: Set<String> {
        RemoteRelayCommandPolicy.surfaceIDKeys
    }

    private nonisolated static var remoteRelayAmbiguousIDKeys: Set<String> {
        RemoteRelayCommandPolicy.ambiguousIDKeys
    }

    private nonisolated static var remoteRelayWorkspaceIDArrayKeys: Set<String> {
        RemoteRelayCommandPolicy.workspaceIDArrayKeys
    }

    private nonisolated static var remoteRelaySurfaceIDArrayKeys: Set<String> {
        RemoteRelayCommandPolicy.surfaceIDArrayKeys
    }

    private nonisolated static var remoteRelayAmbiguousIDArrayKeys: Set<String> {
        RemoteRelayCommandPolicy.ambiguousIDArrayKeys
    }

    nonisolated static func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        remoteWorkspaceID: UUID? = nil
    ) -> Data {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty || remoteWorkspaceID != nil,
              let line = String(data: commandLine, encoding: .utf8) else {
            return commandLine
        }
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let requestData = trimmedLine.data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return commandLine
        }
        let method = (request["method"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteWorkspaceID != nil, let method {
            // The local parser trims method names before dispatch. Normalize
            // the signed envelope to that same value so surrounding wire
            // whitespace cannot produce a MAC mismatch.
            request["method"] = method
        }

        var didRewrite = false
        var params = request["params"] as? [String: Any] ?? [:]
        if remoteWorkspaceID != nil {
            // These fields are relay-owned provenance.  Drop values supplied
            // by the remote process before applying aliases and stamping the
            // authenticated owner below; otherwise a caller could smuggle a
            // second owner/authentication value into the local socket.
            params.removeValue(forKey: "_cmux_remote_workspace_id")
            // Legacy resume MAC: no longer attached or verified, but old remote
            // daemons and clients may still send it, so keep stripping it here.
            params.removeValue(forKey: "_cmux_remote_relay_authentication_code")
            params.removeValue(forKey: "_cmux_remote_relay_request_authentication_code")
            didRewrite = true
        }
        if !params.isEmpty || request["params"] != nil || remoteWorkspaceID != nil {
            params = Self.remappedRemoteRelayValue(
                params,
                key: nil,
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases,
                didRewrite: &didRewrite
            ) as? [String: Any] ?? params
            if let remoteWorkspaceID {
                params["_cmux_remote_workspace_id"] = remoteWorkspaceID.uuidString
                didRewrite = true
            }
            request["params"] = params
        }

        // A caller notification carries a preferred workspace/surface.  Once
        // those selectors are present, normalize it to the membership-confined
        // target method used by the cloud relay; the caller resolver otherwise
        // has permission to fall back to globally focused state.
        if remoteWorkspaceID != nil,
           method == "notification.create_for_caller",
           let preferredWorkspace = params["preferred_workspace_id"],
           let preferredSurface = params["preferred_surface_id"] {
            params["workspace_id"] = preferredWorkspace
            params["surface_id"] = preferredSurface
            params.removeValue(forKey: "preferred_workspace_id")
            params.removeValue(forKey: "preferred_surface_id")
            request["method"] = "notification.create_for_target"
            request["params"] = params
            didRewrite = true
        }

        guard didRewrite,
              JSONSerialization.isValidJSONObject(request),
              let rewritten = try? JSONSerialization.data(withJSONObject: request, options: []) else {
            return commandLine
        }
        if commandLine.last == 0x0A {
            return rewritten + Data([0x0A])
        }
        return rewritten
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
