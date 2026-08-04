import Foundation

func localizedEmptySidebarRenderWarning(locale: Locale = .current) -> String {
    if let localized = localizedSidebarValidationWarning(
        key: "sidebar.custom.validation.emptyRender",
        locale: locale
    ) {
        return localized
    }
    return String(
        localized: LocalizedStringResource(
            "sidebar.custom.validation.emptyRender",
            defaultValue: "Sidebar rendered no visible content.",
            locale: locale,
            bundle: .module
        )
    )
}

func localizedEmptySidebarRenderWithoutOptionalDataWarning(
    locale: Locale = .current
) -> String {
    if let localized = localizedSidebarValidationWarning(
        key: "sidebar.custom.validation.emptyRenderWithoutOptionalData",
        locale: locale
    ) {
        return localized
    }
    return String(
        localized: LocalizedStringResource(
            "sidebar.custom.validation.emptyRenderWithoutOptionalData",
            defaultValue: "Sidebar rendered no visible content when optional workspace data was absent.",
            locale: locale,
            bundle: .module
        )
    )
}

func localizedMissingOptionalDataCoverageWarning(locale: Locale = .current) -> String {
    if let localized = localizedSidebarValidationWarning(
        key: "sidebar.custom.validation.noOptionalDataCoverage",
        locale: locale
    ) {
        return localized
    }
    return String(
        localized: LocalizedStringResource(
            "sidebar.custom.validation.noOptionalDataCoverage",
            defaultValue: "Sidebar output did not change when its referenced optional workspace data was removed.",
            locale: locale,
            bundle: .module
        )
    )
}

/// Resolves a package-owned warning for an explicit locale.
///
/// Xcode app builds provide compiled language tables. SwiftPM's command-line
/// build instead copies the string catalog into the resource bundle verbatim,
/// so fall back to reading that packaged catalog without introducing a second
/// translation source.
private func localizedSidebarValidationWarning(
    key: String,
    locale: Locale
) -> String? {
    let availableLocalizations = Bundle.module.localizations.filter { $0 != "Base" }
    let preferredLocalizations = Bundle.preferredLocalizations(
        from: availableLocalizations,
        forPreferences: [locale.identifier]
    )
    for localization in preferredLocalizations {
        guard
            let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
            let languageBundle = Bundle(path: path)
        else { continue }
        let localized = languageBundle.localizedString(
            forKey: key,
            value: nil,
            table: nil
        )
        if localized != key {
            return localized
        }
    }
    guard let localizations = packagedSidebarValidationStrings[key] else {
        return nil
    }
    let preferredCatalogLocalizations = Bundle.preferredLocalizations(
        from: localizations.keys.sorted(),
        forPreferences: [locale.identifier]
    )
    guard let localization = preferredCatalogLocalizations.first else {
        return nil
    }
    return localizations[localization]
}

private let packagedSidebarValidationStrings: [String: [String: String]] = {
    guard
        let url = Bundle.module.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ),
        let data = try? Data(contentsOf: url),
        let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
        let strings = root["strings"] as? [String: Any]
    else { return [:] }

    var valuesByKey: [String: [String: String]] = [:]
    for (key, rawEntry) in strings {
        guard
            let entry = rawEntry as? [String: Any],
            let localizations = entry["localizations"] as? [String: Any]
        else { continue }
        var valuesByLocalization: [String: String] = [:]
        for (localization, rawValue) in localizations {
            guard
                let value = rawValue as? [String: Any],
                let stringUnit = value["stringUnit"] as? [String: Any],
                let localizedValue = stringUnit["value"] as? String
            else { continue }
            valuesByLocalization[localization] = localizedValue
        }
        valuesByKey[key] = valuesByLocalization
    }
    return valuesByKey
}()
