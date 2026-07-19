import Foundation

extension CMUXCLI {
    func renderSessionListLine(_ payload: [String: Any]) -> String {
        let agent = (payload["agent"] as? String) ?? "unknown"
        let sessionId = (payload["session_id"] as? String)
            ?? (payload["pid"] as? Int).map { "pid \($0)" }
            ?? "unknown"
        let workspaceId = (payload["workspace_id"] as? String) ?? "-"
        let surfaceId = (payload["surface_id"] as? String) ?? "-"
        let cwd = (payload["cwd"] as? String) ?? "-"
        let updatedAt = (payload["updated_at"] as? String) ?? "-"
        let sessionHome = (payload["session_home"] as? String) ?? "-"
        let sessionDir = (payload["session_dir"] as? String) ?? "-"
        let activeWorkspace = ((payload["active_for_workspace"] as? Bool) == true) ? "yes" : "no"
        let activeSurface = ((payload["active_for_surface"] as? Bool) == true) ? "yes" : "no"
        let effectiveState = (payload["effective_state"] as? String) ?? "unknown"
        let activityState = ((payload["activity"] as? [String: Any])?["state"] as? String) ?? "unknown"
        let identitySource = (payload["identity_source"] as? String) ?? "unknown"
        let stateSource = (payload["state_source"] as? String) ?? "unknown"
        let restoreOwner = ((payload["restore_authority"] as? Bool) == true) ? "yes" : "no"
        var parts = [
            "\(agent) \(sessionId)",
            "state=\(effectiveState)",
            "activity=\(activityState)",
            "identity=\(identitySource)",
            "state_source=\(stateSource)",
            "restore_owner=\(restoreOwner)",
            "workspace=\(workspaceId)",
            "surface=\(surfaceId)",
            "cwd=\(cwd)",
            "active_ws=\(activeWorkspace)",
            "active_surface=\(activeSurface)",
            "updated=\(updatedAt)",
        ]
        if agent == "codex" {
            parts.append("session_home=\(sessionHome)")
            let indexed = ((payload["codex_indexed"] as? Bool) == true) ? "yes" : "no"
            let transcript = ((payload["codex_transcript_found"] as? Bool) == true) ? "yes" : "no"
            parts.append("codex_indexed=\(indexed)")
            parts.append("codex_transcript=\(transcript)")
        } else {
            parts.append("session_dir=\(sessionDir)")
        }
        let forkCommandAvailable = ((payload["fork_command_available"] as? Bool) == true) ? "yes" : "no"
        parts.append("fork_command=\(forkCommandAvailable)")
        let forkSupported = ((payload["fork_supported"] as? Bool) == true) ? "yes" : "no"
        parts.append("fork=\(forkSupported)")
        if let pidExists = payload["stored_pid_exists"] as? Bool {
            parts.append("pid_exists=\(pidExists ? "yes" : "no")")
        }
        return parts.joined(separator: "  ")
    }

    func sessionsListTimestamp(_ value: TimeInterval, formatter: ISO8601DateFormatter) -> String {
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }
}
