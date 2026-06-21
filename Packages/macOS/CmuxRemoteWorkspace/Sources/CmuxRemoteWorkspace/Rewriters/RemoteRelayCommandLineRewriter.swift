public import Foundation

/// Rewrites one reverse-CLI-relay command line, remapping remote-issued
/// workspace/surface ID aliases to their local counterparts before the relay
/// forwards the command to the local cmux socket.
///
/// The relay carries JSON-RPC command lines whose `params` may embed
/// workspace/surface UUIDs minted on a different (snapshot) workspace. When a
/// persistent-SSH-PTY session is restored under a new local workspace/surface
/// ID, the alias maps translate the snapshot IDs to the live ones so commands
/// addressed to the old IDs still hit the right targets. Keys are classified
/// by name (scalar vs array, workspace vs surface vs ambiguous `tab_id`), and
/// only string values that parse as UUIDs and have a matching alias are
/// rewritten; everything else passes through byte-for-byte.
///
/// The app's `RemoteRelayCommandRewriting` conformer forwards here so the
/// relay server never imports the workspace model.
///
/// Static members only (justification per the no-namespace-enum convention,
/// matching the sibling `RemoteLoopbackHTTP*Rewriter` transforms): this is a
/// pure JSON-in/JSON-out transform with no state to hold; the alias maps and
/// command bytes are passed in.
// lint:allow namespace-type — stateless pure byte/JSON transform, matching the
// sibling RemoteLoopbackHTTP*Rewriter carve-outs in this folder.
public struct RemoteRelayCommandLineRewriter {
    private static let workspaceIDKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
    ]

    private static let surfaceIDKeys: Set<String> = [
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

    private static let ambiguousIDKeys: Set<String> = [
        "tab_id",
    ]

    private static let workspaceIDArrayKeys: Set<String> = [
        "workspace_ids",
    ]

    private static let surfaceIDArrayKeys: Set<String> = [
        "panel_ids",
        "surface_ids",
    ]

    private static let ambiguousIDArrayKeys: Set<String> = [
        "tab_ids",
        "tab_id_groups",
    ]

    /// Rewrites `commandLine` in place, mapping workspace/surface ID aliases
    /// found in its JSON `params` to their local counterparts. Returns the
    /// input unchanged when there are no aliases, the payload is not a JSON
    /// object, or no alias applied. A trailing newline on the input is
    /// preserved on the output.
    public static func rewrite(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty,
              let line = String(data: commandLine, encoding: .utf8) else {
            return commandLine
        }
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let requestData = trimmedLine.data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return commandLine
        }

        var didRewrite = false
        if let params = request["params"] as? [String: Any] {
            request["params"] = remappedValue(
                params,
                key: nil,
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases,
                didRewrite: &didRewrite
            )
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

    private static func remappedValue(
        _ value: Any,
        key: String?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        didRewrite: inout Bool
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            for (childKey, childValue) in dictionary {
                result[childKey] = remappedValue(
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
            if let key, workspaceIDArrayKeys.contains(key) {
                elementKey = "workspace_id"
            } else if let key, surfaceIDArrayKeys.contains(key) {
                elementKey = "surface_id"
            } else if let key, ambiguousIDArrayKeys.contains(key) {
                elementKey = "tab_id"
            } else if let key, workspaceIDKeys.contains(key)
                        || surfaceIDKeys.contains(key)
                        || ambiguousIDKeys.contains(key) {
                elementKey = key
            } else {
                elementKey = nil
            }
            return array.map {
                remappedValue(
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
        if surfaceIDKeys.contains(key),
           let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if workspaceIDKeys.contains(key),
           let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        guard ambiguousIDKeys.contains(key) else {
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
