/// The diagnostic text settings parsers give a refused value, from its schema row. The address
/// bar's rows themselves are `BrowserSettingsSchema.addressBar` (schemas/settings/source/browser.json).
nonisolated enum OmnibarSettingsSchema {
    /// The diagnostic text for a refused value of `descriptor`.
    static func expectation(_ descriptor: SettingDescriptor) -> String {
        switch descriptor.kind {
        case .toggle: "expected true or false"
        case .choice(let choices): "expected one of " + choices.map { "\"\($0.value)\"" }.joined(separator: ", ")
        case .number(let number): "expected a number from \(Int(number.range.lowerBound)) to \(Int(number.range.upperBound))"
        case .url where BrowserOmnibarSetting.templatePaths.contains(descriptor.path):
            "expected a web address with %s or {searchTerms} where the typed text goes, or \"\""
        case .url: "expected a web address or \"\""
        case .choiceOrNumber(let choices, let number):
            "expected one of " + choices.map { "\"\($0.value)\"" }.joined(separator: ", ")
                + " or a number from \(Int(number.range.lowerBound)) to \(Int(number.range.upperBound))"
        case .choiceOrURL(let choices, let urlKey):
            "expected one of " + choices.map { "\"\($0.value)\"" }.joined(separator: ", ")
                + " or {\"\(urlKey)\": \"http(s)://host[:port]\"}"
        default: "invalid value"
        }
    }
}
