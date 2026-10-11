import CmuxNextDesign

/// The Settings rows of the address bar's suggestion keys (Browser > Address
/// Bar), kept out of `BrowserSettingsSchema` so its catalog stays small.
nonisolated enum OmnibarSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.addressBar", "Address Bar")
        typealias S = BrowserOmnibarSetting
        let fallback = S.fallback
        return [
            SettingDescriptor(
                S.searchEnginePath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.searchEngine", "Search Engine"),
                help: SettingsText.keyed("settings.browser.searchEngine.help", "The address bar searches here and asks it for suggestions."),
                kind: .choice([
                    SettingChoice("google", "Google"), SettingChoice("duckduckgo", "DuckDuckGo"), SettingChoice("bing", "Bing"),
                    SettingChoice("brave", "Brave"), SettingChoice("kagi", "Kagi"),
                    SettingChoice("custom", SettingsText.keyed("settings.choice.searchEngine.custom", "Custom")),
                ]),
                default: .string(fallback.searchEngine), keywords: ["search", "engine", "omnibox", "address bar"]
            ),
            SettingDescriptor(
                S.customSearchPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.customSearch", "Custom Search Address"),
                help: SettingsText.keyed("settings.browser.customSearch.help",
                                         "Used when Search Engine is Custom. Put {searchTerms} where the typed text goes."),
                kind: .url, default: .string(fallback.customSearch), keywords: ["search", "engine", "custom", "template"]
            ),
            SettingDescriptor(
                S.customSuggestPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.customSuggest", "Custom Suggestions Address"),
                help: SettingsText.keyed("settings.browser.customSuggest.help",
                                         "Optional. Answers in the OpenSearch suggestions format, with {searchTerms} for the typed text."),
                kind: .url, default: .string(fallback.customSuggest), keywords: ["search", "suggest", "custom", "opensearch"]
            ),
            SettingDescriptor(
                S.remoteSuggestionsPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.remoteSuggestions", "Search Suggestions"),
                help: SettingsText.keyed("settings.browser.omnibar.remoteSuggestions.help",
                                         "Sends what you type to the search engine for suggestions. Never addresses, files or local hosts."),
                kind: .toggle, default: .bool(fallback.remoteSuggestions), keywords: ["suggest", "search", "omnibox", "privacy"]
            ),
            SettingDescriptor(
                S.inlineAutocompletePath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.inlineAutocomplete", "Complete Addresses Inline"),
                help: SettingsText.keyed("settings.browser.omnibar.inlineAutocomplete.help",
                                         "Completes a site you typed before or visit often."),
                kind: .toggle, default: .bool(fallback.inlineAutocomplete), keywords: ["autocomplete", "omnibox", "address bar"]
            ),
            SettingDescriptor(
                S.maxRowsPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.maxRows", "Suggestions Shown"),
                kind: .number(SettingNumber(S.maxRowsRange, step: 1, unit: .count)), default: .number(Double(fallback.maxRows)),
                keywords: ["suggestions", "rows", "omnibox"]
            ),
            SettingDescriptor(
                S.calculatorPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.calculator", "Calculator Answers"),
                help: SettingsText.keyed("settings.browser.omnibar.calculator.help", "Shows the answer to arithmetic you type. Return copies it."),
                kind: .toggle, default: .bool(fallback.calculator), keywords: ["calculator", "math", "answer", "omnibox"]
            ),
        ]
    }

    /// Agents may change how many rows show and inline completion; the
    /// engine and remote suggestions decide what leaves the machine.
    static var agentSettableKeys: Set<String> {
        ["browser.omnibar.inlineAutocomplete", "browser.omnibar.maxRows", "browser.omnibar.calculator"]
    }

    static var privacyKeys: [String] {
        ["browser.searchEngine", "browser.customSearchEngine.search", "browser.customSearchEngine.suggest", "browser.omnibar.remoteSuggestions"]
    }

    /// The diagnostic text for a refused value of `descriptor`.
    static func expectation(_ descriptor: SettingDescriptor) -> String {
        switch descriptor.kind {
        case .toggle: "expected true or false"
        case .choice(let choices): "expected one of " + choices.map { "\"\($0.value)\"" }.joined(separator: ", ")
        case .number(let number): "expected a number from \(Int(number.range.lowerBound)) to \(Int(number.range.upperBound))"
        case .url where BrowserOmnibarSetting.templatePaths.contains(descriptor.path):
            "expected a web address with %s or {searchTerms} where the typed text goes, or \"\""
        case .url: "expected a web address or \"\""
        default: "invalid value"
        }
    }
}
