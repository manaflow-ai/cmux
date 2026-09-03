import Foundation

extension CMUXCLI {
    /// Adds stable aliases for the workspace that produced an action result.
    ///
    /// The ordinary `workspace_id` / `workspace_ref` pair is still shaped by
    /// `--id-format`. The `aimed_*` aliases are intentionally copied before
    /// that shaping so automation can always assert both the resolved short
    /// ref and UUID after a workspace-scoped command completes.
    func payloadWithAimedWorkspaceMetadata(_ payload: [String: Any]) -> [String: Any] {
        var output = payload
        if output["aimed_workspace_id"] == nil,
           let workspaceID = payload["workspace_id"] as? String,
           !workspaceID.isEmpty {
            output["aimed_workspace_id"] = workspaceID
        }
        if output["aimed_workspace_ref"] == nil,
           let workspaceRef = payload["workspace_ref"] as? String,
           !workspaceRef.isEmpty {
            output["aimed_workspace_ref"] = workspaceRef
        }
        return output
    }

    /// Formats a JSON response while keeping the explicit aimed-workspace
    /// aliases independent of the selected ordinary ID presentation.
    func formatAimedWorkspacePayload(
        _ payload: [String: Any],
        mode: CLIIDFormat,
        preservingIDKinds: Set<String> = []
    ) -> [String: Any] {
        let withMetadata = payloadWithAimedWorkspaceMetadata(payload)
        var formatted = (formatIDs(
            withMetadata,
            mode: mode,
            preservingIDKinds: preservingIDKinds
        ) as? [String: Any]) ?? withMetadata

        // `formatIDs` quite correctly removes one half of ordinary pairs for
        // `.refs`/`.uuids`; aimed aliases are the opt-in assertion contract,
        // so restore both values after that presentation pass.
        for key in ["aimed_workspace_id", "aimed_workspace_ref"] {
            if let value = withMetadata[key] {
                formatted[key] = value
            }
        }
        return formatted
    }

    func formatAimedWorkspaceInspectionIDs(
        _ object: Any,
        mode: CLIIDFormat,
        preserveStableIDs: Bool
    ) -> Any {
        let preservingIDKinds: Set<String> = preserveStableIDs ? ["workspace"] : []
        guard let payload = object as? [String: Any] else {
            return formatIDs(object, mode: mode, preservingIDKinds: preservingIDKinds)
        }
        return formatAimedWorkspacePayload(
            payload,
            mode: mode,
            preservingIDKinds: preservingIDKinds
        )
    }

    /// Serializes a response which already carries its ordinary workspace
    /// identity without applying an ID-format projection (for example,
    /// `read-screen` preserves the full response shape).
    func jsonStringWithAimedWorkspace(_ payload: [String: Any]) -> String {
        jsonString(payloadWithAimedWorkspaceMetadata(payload))
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.sortedKeys)
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }
}
