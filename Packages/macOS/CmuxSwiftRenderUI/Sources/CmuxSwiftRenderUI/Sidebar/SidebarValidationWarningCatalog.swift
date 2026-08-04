import Foundation

/// Decodes validation warning strings from a package-owned string catalog.
struct SidebarValidationWarningCatalog {
    /// Localized values keyed first by message key, then locale identifier.
    let strings: [String: [String: String]]

    /// Loads localized string values from the supplied resource bundle.
    init(bundle: Bundle) {
        guard
            let url = bundle.url(
                forResource: "Localizable",
                withExtension: "xcstrings"
            ),
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let catalogStrings = root["strings"] as? [String: Any]
        else {
            self.strings = [:]
            return
        }

        var valuesByKey: [String: [String: String]] = [:]
        for (key, rawEntry) in catalogStrings {
            guard
                let entry = rawEntry as? [String: Any],
                let localizations = entry["localizations"]
                    as? [String: Any]
            else {
                continue
            }
            var valuesByLocalization: [String: String] = [:]
            for (localization, rawValue) in localizations {
                guard
                    let value = rawValue as? [String: Any],
                    let stringUnit = value["stringUnit"]
                        as? [String: Any],
                    let localizedValue = stringUnit["value"] as? String
                else {
                    continue
                }
                valuesByLocalization[localization] = localizedValue
            }
            valuesByKey[key] = valuesByLocalization
        }
        self.strings = valuesByKey
    }
}
