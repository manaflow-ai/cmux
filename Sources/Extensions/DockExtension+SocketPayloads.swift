import CmuxDockExtensions
import Foundation

extension InstalledDockExtension {
    /// The `extension.list` socket payload for this installed extension.
    var socketPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": record.id,
            "name": displayName,
            "source": record.source.description,
            "enabled": record.enabled,
            "linked": isLinked,
            "root": rootDirectory.path,
        ]
        if let version = manifest?.version { payload["version"] = version }
        if let sha = record.pinnedSha { payload["pinned_sha"] = sha }
        if let ref = record.ref { payload["ref"] = ref }
        switch status {
        case .ok:
            payload["status"] = "ok"
        case .needsReconsent:
            payload["status"] = "needs_reconsent"
        case .manifestUnavailable(let message):
            payload["status"] = "unavailable"
            payload["status_message"] = message
        }
        payload["panes"] = launchablePanes.map { pane in
            [
                "id": pane.id,
                "qualified_id": DockExtensionPane.qualifiedId(extensionId: record.id, paneId: pane.id),
                "title": pane.title,
            ] as [String: Any]
        }
        return payload
    }
}

extension DockExtensionInstallPreview {
    /// The `extension.preview` socket payload: everything the CLI shows
    /// before asking for consent, plus the one-shot confirmation token.
    func socketPayload(token: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "version": manifest.version,
            "source": source.description,
            "warnings": warnings,
        ]
        if let token { payload["preview_token"] = token }
        if let resolvedSha { payload["resolved_sha"] = resolvedSha }
        if let ref { payload["ref"] = ref }
        if let description = manifest.description { payload["description"] = description }
        if let minimum = manifest.minCmuxVersion { payload["min_cmux_version"] = minimum.rawValue }
        switch kind {
        case .install:
            payload["kind"] = "install"
        case .update(let previousSha):
            payload["kind"] = "update"
            if let previousSha { payload["previous_sha"] = previousSha }
        }
        payload["build_commands"] = manifest.buildStepsForCurrentPlatform.map(\.shellCommand)
        payload["panes"] = manifest.panesForCurrentPlatform.map { pane in
            var panePayload: [String: Any] = [
                "id": pane.id,
                "title": pane.title,
                "command": pane.shellCommand,
            ]
            if let cwd = pane.cwd { panePayload["cwd"] = cwd }
            if !pane.env.isEmpty {
                // Full assignments: the CLI preview is a trust boundary, and
                // env values (PATH, NODE_OPTIONS, DYLD_*) change what runs.
                panePayload["env"] = pane.env
            }
            return panePayload
        }
        return payload
    }
}
