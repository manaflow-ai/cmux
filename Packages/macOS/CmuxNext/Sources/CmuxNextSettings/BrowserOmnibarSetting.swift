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
///   "omnibar": { "remoteSuggestions": true, "inlineAutocomplete": true, "maxRows": 8 }
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
    /// The built-in engines, then `custom`.
    public static let engines = ["google", "duckduckgo", "bing", "brave", "kagi", "custom"]
    public static let maxRowsRange: ClosedRange<Double> = 3...15

    public var searchEngine = "google"
    public var customSearch = ""
    public var customSuggest = ""
    public var remoteSuggestions = true
    public var inlineAutocomplete = true
    public var maxRows = 8

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
            default: break
            }
        }
        return setting
    }
}
