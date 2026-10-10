import Foundation

/// The address bar's suggestion keys in cmux.json
/// (plans/cmux-next/omnibar-suggestions.md, "Settings"):
///
/// ```jsonc
/// "browser": {
///   "searchEngine": "google",          // duckduckgo, bing, brave, kagi, custom
///   "customSearchEngine": {            // used when searchEngine is "custom"
///     "search": "https://example.com/search?q=%s",
///     "suggest": "https://example.com/suggest?q=%s"   // optional, OpenSearch JSON
///   },
///   "omnibar": { "remoteSuggestions": true, "inlineAutocomplete": true, "maxRows": 8, "calculator": true,
///                // the bar's look (cx-gkz5):
///                "glass": "regular",            // clear, off
///                "glassTint": "background",     // accent, none
///                "glassTintStrength": 0.35,     // 0 to 1
///                "cornerRadius": "theme",       // capsule, or points 0 to 16
///                "shadow": false }
/// }
/// ```
///
/// `%s` or `{searchTerms}` marks where the typed text goes. A bad value is
/// that key's default plus a diagnostic at its key.
public nonisolated struct BrowserOmnibarSetting: Sendable, Hashable {
    public static let searchEnginePath = ["browser", "searchEngine"]
    public static let customSearchPath = ["browser", "customSearchEngine", "search"]
    public static let customSuggestPath = ["browser", "customSearchEngine", "suggest"]
    public static let remoteSuggestionsPath = ["browser", "omnibar", "remoteSuggestions"]
    public static let inlineAutocompletePath = ["browser", "omnibar", "inlineAutocomplete"]
    public static let maxRowsPath = ["browser", "omnibar", "maxRows"]
    public static let calculatorPath = ["browser", "omnibar", "calculator"]
    public static let glassPath = ["browser", "omnibar", "glass"]
    public static let glassTintPath = ["browser", "omnibar", "glassTint"]
    public static let glassTintStrengthPath = ["browser", "omnibar", "glassTintStrength"]
    public static let cornerRadiusPath = ["browser", "omnibar", "cornerRadius"]
    public static let shadowPath = ["browser", "omnibar", "shadow"]
    /// `glass` values.
    public static let glassStyles = ["regular", "clear", "off"]
    /// `glassTint` values.
    public static let glassTints = ["background", "accent", "none"]
    /// `cornerRadius` words; a number is points in `cornerRadiusRange`.
    public static let cornerRadiusWords = ["theme", "capsule"]
    public static let cornerRadiusRange: ClosedRange<Double> = 0...16
    /// The built-in engines, then `custom`.
    public static let engines = ["google", "duckduckgo", "bing", "brave", "kagi", "custom"]
    public static let maxRowsRange: ClosedRange<Double> = 3...15
    /// The custom engine's addresses: each must mark where the typed text goes.
    public static let templatePaths = [customSearchPath, customSuggestPath]

    /// Empty (no custom address), or a web address with `%s` or
    /// `{searchTerms}`. A search address without one would search for the
    /// same page whatever was typed, so it is refused when written and
    /// reported when loaded.
    public static func isSearchTemplate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard trimmed.contains("%s") || trimmed.contains("{searchTerms}") else { return false }
        return BrowserNewTabPage.url(from: trimmed.replacingOccurrences(of: "%s", with: "x")
            .replacingOccurrences(of: "{searchTerms}", with: "x")) != nil
    }

    public var searchEngine = "google"
    public var customSearch = ""
    public var customSuggest = ""
    public var remoteSuggestions = true
    public var inlineAutocomplete = true
    public var maxRows = 8
    public var calculator = true
    public var glass = "regular"
    public var glassTint = "background"
    public var glassTintStrength = 0.35
    /// nil: the theme's radius; `.infinity`: a capsule; else points.
    public var cornerRadius: Double?
    public var shadow = false

    public init() {}

    public static let fallback = BrowserOmnibarSetting()

    /// Each key is checked against its schema row (`OmnibarSettingsSchema`),
    /// so the parser and the Settings window agree on what is valid.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BrowserOmnibarSetting {
        var setting = fallback
        for descriptor in OmnibarSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path) else { continue }
            guard descriptor.accepts(value) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            switch descriptor.path {
            case searchEnginePath: setting.searchEngine = value.stringValue ?? setting.searchEngine
            case customSearchPath: setting.customSearch = value.stringValue ?? ""
            case customSuggestPath: setting.customSuggest = value.stringValue ?? ""
            case remoteSuggestionsPath: setting.remoteSuggestions = value.boolValue ?? true
            case inlineAutocompletePath: setting.inlineAutocomplete = value.boolValue ?? true
            case maxRowsPath: setting.maxRows = Int(value.doubleValue ?? 8)
            case calculatorPath: setting.calculator = value.boolValue ?? true
            case glassPath: setting.glass = value.stringValue ?? setting.glass
            case glassTintPath: setting.glassTint = value.stringValue ?? setting.glassTint
            case glassTintStrengthPath: setting.glassTintStrength = value.doubleValue ?? setting.glassTintStrength
            case cornerRadiusPath:
                switch value.stringValue {
                case "theme": setting.cornerRadius = nil
                case "capsule": setting.cornerRadius = .infinity
                default: setting.cornerRadius = value.doubleValue
                }
            case shadowPath: setting.shadow = value.boolValue ?? false
            default: break
            }
        }
        return setting
    }
}
