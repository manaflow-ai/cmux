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
///                "showFullURLs": false,         // the whole address, scheme and www. included
///                // the bar's look (cx-gkz5):
///                "glass": "off",                // transparent, regular, clear
///                "glassTint": "background",     // accent, none
///                "glassTintStrength": 0.35,     // 0 to 1
///                "cornerRadius": "theme",       // capsule, or points 0 to 16
///                "shadow": false,
///                "backgroundOpacity": 0,        // 0 to 1, over a see-through window
///                // the bar's size (issue 28734): "density" follows the density preset
///                "height": "density",           // or points 20 to 56
///                "fontSize": "density" }        // or points 10 to 24
/// }
/// ```
///
/// `%s` or `{searchTerms}` marks where the typed text goes. A bad value is
/// that key's default plus a diagnostic at its key. Each key's path, default, range and words
/// (`searchEngineValues`: the built-in engines, then `custom`) come from
/// schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserOmnibarSetting: Sendable, Hashable {
    /// The paths whose number is clamped into range (with a diagnostic) instead of refused.
    static let clampedPaths: [[String]: ClosedRange<Double>] = [heightPath: heightRange, fontSizePath: fontSizeRange]
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

    public var searchEngine = BrowserOmnibarSetting.searchEngineDefault
    public var customSearch = BrowserOmnibarSetting.customSearchDefault
    public var customSuggest = BrowserOmnibarSetting.customSuggestDefault
    public var remoteSuggestions = BrowserOmnibarSetting.remoteSuggestionsDefault
    public var inlineAutocomplete = BrowserOmnibarSetting.inlineAutocompleteDefault
    public var maxRows = Int(BrowserOmnibarSetting.maxRowsDefault)
    public var calculator = BrowserOmnibarSetting.calculatorDefault
    /// The bar shows the whole address at rest (no elided `https://` or `www.`).
    public var showFullURLs = BrowserOmnibarSetting.showFullURLsDefault
    public var glass = BrowserOmnibarSetting.glassDefault
    public var glassTint = BrowserOmnibarSetting.glassTintDefault
    public var glassTintStrength = BrowserOmnibarSetting.glassTintStrengthDefault
    /// nil: the theme's radius; `.infinity`: a capsule; else points.
    public var cornerRadius: Double?
    public var shadow = BrowserOmnibarSetting.shadowDefault
    /// How much the flat bar covers a see-through window, 0 to 1; 0 keeps
    /// the window's transparency down to the text's legibility floor.
    public var backgroundOpacity = BrowserOmnibarSetting.backgroundOpacityDefault
    /// The bar's height in points; nil follows density.
    public var height: Double?
    /// The bar's text size in points; nil follows density.
    public var fontSize: Double?

    public init() {}

    public static let fallback = BrowserOmnibarSetting()

    /// Each key is checked against its schema row (`BrowserSettingsSchema.addressBar`),
    /// so the parser and the Settings window agree on what is valid.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BrowserOmnibarSetting {
        var setting = fallback
        for descriptor in BrowserSettingsSchema.addressBar {
            guard var value = root.value(at: descriptor.path) else { continue }
            if let range = clampedPaths[descriptor.path], let number = value.doubleValue, number.isFinite, !range.contains(number) {
                // A size past its range applies at the nearest end, and says so.
                let clamped = min(max(number, range.lowerBound), range.upperBound)
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id,
                                                      message: OmnibarSettingsSchema.expectation(descriptor) + "; using \(Int(clamped))"))
                value = .number(clamped)
            }
            guard descriptor.accepts(value) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            switch descriptor.path {
            case searchEnginePath: setting.searchEngine = value.stringValue ?? setting.searchEngine
            case customSearchPath: setting.customSearch = value.stringValue ?? setting.customSearch
            case customSuggestPath: setting.customSuggest = value.stringValue ?? setting.customSuggest
            case remoteSuggestionsPath: setting.remoteSuggestions = value.boolValue ?? setting.remoteSuggestions
            case inlineAutocompletePath: setting.inlineAutocomplete = value.boolValue ?? setting.inlineAutocomplete
            case maxRowsPath: setting.maxRows = value.doubleValue.map { Int($0) } ?? setting.maxRows
            case calculatorPath: setting.calculator = value.boolValue ?? setting.calculator
            case showFullURLsPath: setting.showFullURLs = value.boolValue ?? setting.showFullURLs
            case glassPath: setting.glass = value.stringValue ?? setting.glass
            case glassTintPath: setting.glassTint = value.stringValue ?? setting.glassTint
            case glassTintStrengthPath: setting.glassTintStrength = value.doubleValue ?? setting.glassTintStrength
            case cornerRadiusPath:
                switch value.stringValue {
                case "theme": setting.cornerRadius = nil
                case "capsule": setting.cornerRadius = .infinity
                default: setting.cornerRadius = value.doubleValue
                }
            case shadowPath: setting.shadow = value.boolValue ?? setting.shadow
            case backgroundOpacityPath: setting.backgroundOpacity = value.doubleValue ?? setting.backgroundOpacity
            case heightPath: setting.height = value.stringValue == "density" ? nil : value.doubleValue
            case fontSizePath: setting.fontSize = value.stringValue == "density" ? nil : value.doubleValue
            default: break
            }
        }
        return setting
    }
}
