import Foundation

extension TerminalTextBoxInputSettings {
    static func submitActions(defaults: UserDefaults = .standard) -> [TextBoxSubmitAction] {
        if let data = defaults.data(forKey: submitActionsKey),
           let decoded = try? JSONDecoder().decode([TextBoxSubmitAction].self, from: data) {
            return TextBoxSubmitAction.normalizedCatalog(decoded)
        }
        return submitActions(configuredJSON: defaults.string(forKey: submitActionsKey))
    }

    static func submitActions(configuredJSON raw: String?) -> [TextBoxSubmitAction] {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TextBoxSubmitAction].self, from: data) else {
            return TextBoxSubmitAction.selectableActions
        }
        return TextBoxSubmitAction.normalizedCatalog(decoded)
    }

    static func defaultSubmitActionIDValue(defaults: UserDefaults = .standard) -> String {
        let configured = defaults.string(forKey: defaultSubmitActionKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = submitActions(defaults: defaults)
        if configured == TextBoxSubmitAction.textEntryAction.id {
            return TextBoxSubmitAction.textEntryAction.id
        }
        guard let configured,
              !configured.isEmpty else {
            return defaultSubmitActionID
        }
        guard actions.contains(where: { $0.id == configured }) else {
            return TextBoxSubmitAction.selectableActions.contains(where: { $0.id == configured })
                ? defaultSubmitActionID
                : TextBoxSubmitAction.textEntryAction.id
        }
        return configured
    }

    static func rememberedSubmitActionIDValue(defaults: UserDefaults = .standard) -> String? {
        guard let remembered = defaults.string(forKey: lastSelectedSubmitActionKey),
              !remembered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              submitActions(defaults: defaults).contains(where: { $0.id == remembered }) else {
            return nil
        }
        return remembered
    }

    static func rememberSubmitActionID(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              submitActions(defaults: defaults).contains(where: { $0.id == id }) else {
            return false
        }
        defaults.set(id, forKey: lastSelectedSubmitActionKey)
        return true
    }
}
