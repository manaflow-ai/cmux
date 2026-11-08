public import Foundation

/// Converts an `agent.hook.enqueue` request that passed the relay gates into
/// the app's queue parameters.
///
/// The relay gates have already scoped `workspace_id` and `surface_id` to the
/// owner workspace. Those selectors become the only replay environment, and
/// host paths are dropped from the payload because the remote host is
/// untrusted: the Mac replays the event locally and must never open a
/// same-named path on its own disk.
public struct RemoteRelayAgentHookAdmission: Sendable {
    /// Payload keys that name paths on the remote host.
    static let filesystemPayloadKeys: Set<String> = [
        "cwd", "working_directory", "workingDirectory",
        "project_dir", "projectDir", "project_path", "projectPath",
        "workspacePaths", "workspace_paths",
        "transcript_path", "transcriptPath", "agent_transcript_path",
    ]

    /// Creates the stateless admission transform.
    public init() {}

    /// Rebuilds a relay-admitted hook request for the local delivery queue.
    ///
    /// - Parameter parameters: Decoded request parameters carrying relay provenance.
    /// - Returns: Queue parameters with a selector-derived environment, or `nil`
    ///   when the selectors or required fields are missing.
    public func queueParameters(from parameters: [String: Any]) -> [String: Any]? {
        guard let workspaceID = parameters["workspace_id"] as? String,
              UUID(uuidString: workspaceID) != nil,
              let surfaceID = parameters["surface_id"] as? String,
              UUID(uuidString: surfaceID) != nil,
              let agent = parameters["agent"] as? String,
              let subcommand = parameters["subcommand"] as? String,
              let payload = parameters["payload"] as? String else {
            return nil
        }
        var admitted: [String: Any] = [
            "agent": agent,
            "subcommand": subcommand,
            "payload": portablePayload(payload),
            "relay_backed": true,
            "environment": [
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
            ],
        ]
        let ownerKey = RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey
        admitted[ownerKey] = parameters[ownerKey]
        if let callerTTY = parameters["caller_tty"] as? String {
            admitted["caller_tty"] = callerTTY
        }
        return admitted
    }

    /// Re-encodes a JSON object payload without remote host paths.
    ///
    /// - Parameter payload: The hook payload as sent by the remote host.
    /// - Returns: Sorted-key JSON without path keys, or `{}` when the payload
    ///   is not a JSON object.
    public func portablePayload(_ payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let portable = removingFilesystemKeys(object) as? [String: Any],
              JSONSerialization.isValidJSONObject(portable),
              let encoded = try? JSONSerialization.data(
                  withJSONObject: portable,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: encoded, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Recursively drops `filesystemPayloadKeys` from objects and arrays.
    private func removingFilesystemKeys(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var portable: [String: Any] = [:]
            for (key, child) in object where !Self.filesystemPayloadKeys.contains(key) {
                portable[key] = removingFilesystemKeys(child)
            }
            return portable
        }
        if let array = value as? [Any] {
            return array.map(removingFilesystemKeys)
        }
        return value
    }
}
