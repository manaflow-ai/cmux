import Foundation

/// Supplies provider-aware model choices and the command-line arguments they represent.
struct GuiModeModelCatalog {
    static let defaultReasoningEffort = "extra-high"

    static func options(for provider: GuiModeProviderID) -> [GuiModeModelOption] {
        switch provider {
        case .codex:
            return [
                GuiModeModelOption(
                    id: "gpt-6-astra",
                    displayName: "GPT-6 Astra",
                    reasoningEfforts: ["low", "medium", "high", "extra-high"]
                ),
                GuiModeModelOption(
                    id: "gpt-5.5",
                    displayName: "GPT-5.5",
                    reasoningEfforts: ["low", "medium", "high"]
                )
            ]
        case .claude:
            return [
                GuiModeModelOption(
                    id: "claude-sonnet-4.5",
                    displayName: "Claude Sonnet 4.5",
                    reasoningEfforts: ["default"]
                ),
                GuiModeModelOption(
                    id: "claude-opus-4.1",
                    displayName: "Claude Opus 4.1",
                    reasoningEfforts: ["default"]
                )
            ]
        case .opencode:
            return [
                GuiModeModelOption(id: "default", displayName: "Default", reasoningEfforts: ["default"])
            ]
        default:
            return [GuiModeModelOption(id: "default", displayName: "Default", reasoningEfforts: ["default"])]
        }
    }

    static func defaultOption(for provider: GuiModeProviderID) -> GuiModeModelOption {
        options(for: provider).first ?? GuiModeModelOption(
            id: "default", displayName: "Default", reasoningEfforts: ["default"]
        )
    }

    static func option(
        provider: GuiModeProviderID,
        id: String?
    ) -> GuiModeModelOption {
        guard let id,
              let option = options(for: provider).first(where: { $0.id == id }) else {
            return defaultOption(for: provider)
        }
        return option
    }

    static func normalizedReasoningEffort(
        provider: GuiModeProviderID,
        modelID: String?,
        requested: String?
    ) -> String {
        let option = option(provider: provider, id: modelID)
        if let requested,
           option.reasoningEfforts.contains(requested) {
            return requested
        }
        if option.reasoningEfforts.contains(defaultReasoningEffort) {
            return defaultReasoningEffort
        }
        return option.reasoningEfforts.first ?? "default"
    }

    static func launchCommand(
        provider: GuiModeProviderID,
        modelID: String?,
        reasoningEffort: String?,
        permissionMode: String?
    ) -> String {
        let model = option(provider: provider, id: modelID)
        let effort = normalizedReasoningEffort(provider: provider, modelID: model.id, requested: reasoningEffort)
        var parts: [String]
        switch provider {
        case .codex:
            switch permissionMode {
            case "full-access":
                parts = ["codex", "--dangerously-bypass-approvals-and-sandbox"]
            case "auto-review":
                parts = ["codex", "--full-auto"]
            case "custom":
                // Custom deliberately leaves provider policy to Codex config.toml.
                parts = ["codex"]
            default:
                parts = ["codex", "-a", "on-request", "-s", "workspace-write"]
            }
            if model.id != "default" {
                parts.append(contentsOf: ["--model", shellQuoted(model.id)])
            }
            if effort != "default" {
                parts.append(contentsOf: ["-c", shellQuoted("model_reasoning_effort=\(effort)")])
            }
        case .claude:
            parts = ["claude"]
            if model.id != "default" {
                parts.append(contentsOf: ["--model", shellQuoted(model.id)])
            }
        case .opencode:
            parts = ["opencode"]
            if model.id != "default" {
                parts.append(contentsOf: ["-m", shellQuoted(model.id)])
            }
        default:
            parts = [provider.launchCommand]
        }
        return parts.joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
