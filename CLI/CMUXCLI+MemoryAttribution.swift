import Foundation

extension CMUXCLI {
    func memoryGroupAttributionText(
        _ group: [String: Any],
        idFormat: CLIIDFormat
    ) -> String {
        guard let groupAttribution = group["group_attribution"] as? [String: Any],
              let kind = groupAttribution["kind"] as? String else {
            return memoryAttributionText(group["top_attribution"], idFormat: idFormat)
        }
        switch kind {
        case "common":
            return memoryAttributionText(groupAttribution["owner"], idFormat: idFormat)
        case "multiple":
            let workspaceCount = topInt(groupAttribution["workspace_count"]) ?? 0
            if workspaceCount > 1 {
                return String.localizedStringWithFormat(
                    String(localized: "memory.attribution.multipleWorkspaces", defaultValue: "%lld workspaces", bundle: .cmuxCLI),
                    workspaceCount
                )
            }
            return String(localized: "memory.attribution.multipleOwners", defaultValue: "multiple owners", bundle: .cmuxCLI)
        case "partial":
            return String(localized: "memory.attribution.partial", defaultValue: "partially attributed", bundle: .cmuxCLI)
        case "unattributed":
            return String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed", bundle: .cmuxCLI)
        default:
            return memoryAttributionText(group["top_attribution"], idFormat: idFormat)
        }
    }

    private func memoryAttributionText(_ raw: Any?, idFormat: CLIIDFormat) -> String {
        guard let attribution = raw as? [String: Any] else {
            return String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed", bundle: .cmuxCLI)
        }

        var parts: [String] = []
        if let workspace = memoryAttributionHandle(attribution, prefix: "workspace", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.workspaceAttribution", defaultValue: "workspace %@", bundle: .cmuxCLI),
                workspace
            ))
        }
        if let pane = memoryAttributionHandle(attribution, prefix: "pane", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.paneAttribution", defaultValue: "pane %@", bundle: .cmuxCLI),
                pane
            ))
        }
        if let surface = memoryAttributionHandle(attribution, prefix: "surface", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.surfaceAttribution", defaultValue: "surface %@", bundle: .cmuxCLI),
                surface
            ))
        }
        return parts.isEmpty
            ? String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed", bundle: .cmuxCLI)
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
