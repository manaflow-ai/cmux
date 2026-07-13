import Foundation

struct TextBoxSettingsSubmitActionOptions {
    let builtInOptions: [TextBoxSettingsSubmitActionOption] = [
        TextBoxSettingsSubmitActionOption(
            id: "text-entry",
            title: String(localized: "settings.textBox.submitAction.textEntry", defaultValue: "Text Entry")
        ),
        TextBoxSettingsSubmitActionOption(
            id: "claude",
            title: String(localized: "settings.textBox.submitAction.claude", defaultValue: "Claude")
        ),
        TextBoxSettingsSubmitActionOption(
            id: "codex",
            title: String(localized: "settings.textBox.submitAction.codex", defaultValue: "Codex")
        ),
        TextBoxSettingsSubmitActionOption(
            id: "opencode",
            title: String(localized: "settings.textBox.submitAction.opencode", defaultValue: "OpenCode")
        ),
        TextBoxSettingsSubmitActionOption(
            id: "pi",
            title: String(localized: "settings.textBox.submitAction.pi", defaultValue: "Pi")
        ),
    ]

    func normalizedOptions(configuredJSON: String, currentID: String) -> [TextBoxSettingsSubmitActionOption] {
        var optionsByID: [String: TextBoxSettingsSubmitActionOption] = [:]
        var orderedIDs: [String] = []

        func append(_ option: TextBoxSettingsSubmitActionOption) {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            if optionsByID[id] == nil {
                orderedIDs.append(id)
            }
            optionsByID[id] = TextBoxSettingsSubmitActionOption(
                id: id,
                title: option.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : option.title
            )
        }

        builtInOptions.forEach(append)
        if let data = configuredJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([TextBoxSettingsSubmitActionOption].self, from: data) {
            decoded.forEach(append)
        }
        if !currentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           optionsByID[currentID] == nil {
            append(TextBoxSettingsSubmitActionOption(id: currentID, title: currentID))
        }
        return orderedIDs.compactMap { optionsByID[$0] }
    }
}
