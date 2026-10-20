public import Foundation

extension ManagedPreferences {
    /// The cmux managed values that Chrome policies stand for
    /// (plans/cmux-next/chrome-enterprise-policy-DESIGN.md, "Mapped"):
    /// mandatory policies become forced settings (Settings shows "Managed by
    /// your organization"), recommended ones become recommended settings.
    /// `URLBlocklist`, `URLAllowlist` and `ExtensionInstallForcelist` count
    /// only when mandatory (Chrome never reads them as recommended) and stay
    /// policy keys under their Chrome names. A value of the wrong type is ignored.
    public init(chromePolicy: ChromePolicyDocument) {
        self.init(forced: Self.settings(fromChromePolicies: chromePolicy.mandatory),
                  recommended: Self.settings(fromChromePolicies: chromePolicy.recommended))
        for key in ["URLBlocklist", "URLAllowlist", "ExtensionInstallForcelist"] {
            guard case .array(let items) = chromePolicy.mandatory[key] else { continue }
            let strings = items.compactMap(\.stringValue).filter { !$0.isEmpty }
            if !strings.isEmpty { forced[key] = .array(strings.map(JSONValue.string)) }
        }
    }

    /// The cmux.json keys one level (mandatory or recommended) of Chrome policies sets.
    static func settings(fromChromePolicies policies: [String: JSONValue]) -> [String: JSONValue] {
        var settings: [String: JSONValue] = [:]
        if policies["DefaultSearchProviderEnabled"]?.boolValue != false,
           let search = policies["DefaultSearchProviderSearchURL"]?.stringValue?.trimmingCharacters(in: .whitespaces),
           search.contains("{searchTerms}"), let url = URL(string: search.replacingOccurrences(of: "{searchTerms}", with: "q")),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            settings["browser.searchEngine"] = "custom"
            settings["browser.customSearchEngine.search"] = .string(search)
            let suggest = policies["DefaultSearchProviderSuggestURL"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            settings["browser.customSearchEngine.suggest"] = .string(suggest.contains("{searchTerms}") ? suggest : "")
        }
        if let page = policies["NewTabPageLocation"]?.stringValue, let url = BrowserNewTabPage.url(from: page),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            settings["browser.newTabPage"] = .string(url.absoluteString)
        }
        if let enabled = policies["PasswordManagerEnabled"]?.boolValue {
            settings["browser.passwords.offerToSave"] = .bool(enabled)
            settings["browser.passwords.generate"] = .bool(enabled)
        }
        return settings
    }
}
