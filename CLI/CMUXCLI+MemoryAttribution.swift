import Foundation

extension CMUXCLI {
    /// Formats group ownership and its evidence for CLI output.
    func memoryGroupAttributionText(
        _ group: [String: Any],
        idFormat: CLIIDFormat
    ) -> String {
        guard let groupAttribution = group["group_attribution"] as? [String: Any],
              let kind = groupAttribution["kind"] as? String else {
            return memoryAttributionText(group["top_attribution"], idFormat: idFormat)
        }
        let text: String
        switch kind {
        case "common":
            text = memoryAttributionText(groupAttribution["owner"], idFormat: idFormat)
        case "multiple":
            let workspaceCount = topInt(groupAttribution["workspace_count"]) ?? 0
            if workspaceCount > 1 {
                text = String.localizedStringWithFormat(
                    String(localized: "memory.attribution.multipleWorkspaces", defaultValue: "%lld workspaces"),
                    workspaceCount
                )
            } else {
                text = String(localized: "memory.attribution.multipleOwners", defaultValue: "multiple owners")
            }
        case "partial":
            text = String(localized: "memory.attribution.partial", defaultValue: "partially attributed")
        case "unattributed":
            text = String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed")
        default:
            text = memoryAttributionText(group["top_attribution"], idFormat: idFormat)
        }
        return memoryAttributionWithReason(text, reason: groupAttribution["reason"] as? String)
    }

    /// Appends a localized ownership-evidence label when one is available.
    private func memoryAttributionWithReason(_ text: String, reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return text }
        let evidence = String.localizedStringWithFormat(
            String(localized: "memory.attribution.evidence", defaultValue: "evidence: %@"),
            reason
        )
        return text + " [" + evidence + "]"
    }

    private func memoryAttributionText(_ raw: Any?, idFormat: CLIIDFormat) -> String {
        guard let attribution = raw as? [String: Any] else {
            return String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed")
        }

        var parts: [String] = []
        if let workspace = memoryAttributionHandle(attribution, prefix: "workspace", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.workspaceAttribution", defaultValue: "workspace %@"),
                workspace
            ))
        }
        if let pane = memoryAttributionHandle(attribution, prefix: "pane", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.paneAttribution", defaultValue: "pane %@"),
                pane
            ))
        }
        if let surface = memoryAttributionHandle(attribution, prefix: "surface", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.surfaceAttribution", defaultValue: "surface %@"),
                surface
            ))
        }
        return parts.isEmpty
            ? String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed")
            : parts.joined(separator: " / ")
    }

    private func memoryAttributionHandle(
        _ attribution: [String: Any],
        prefix: String,
        idFormat: CLIIDFormat
    ) -> String? {
        let ref = topLabelText(attribution["\(prefix)_ref"] as? String)
        let id = topLabelText(attribution["\(prefix)_id"] as? String)
        switch idFormat {
        case .refs:
            return ref.isEmpty ? (id.isEmpty ? nil : id) : ref
        case .uuids:
            return id.isEmpty ? (ref.isEmpty ? nil : ref) : id
        case .both:
            let values = [ref, id].filter { !$0.isEmpty }
            return values.isEmpty ? nil : values.joined(separator: " ")
        }
    }
}
