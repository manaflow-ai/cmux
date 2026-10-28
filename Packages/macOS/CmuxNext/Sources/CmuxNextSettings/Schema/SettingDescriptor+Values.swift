import Foundation

extension SettingDescriptor {
    /// The value stored in `root`, or nil when the key is absent. A renamed
    /// key that is absent reads its old key, as the parser does, so Settings
    /// shows the value the app applies.
    public func storedValue(in root: JSONValue) -> JSONValue? {
        root.value(at: path) ?? RenamedSettingKeys.legacyValue(for: path, in: root)
    }

    /// The stored value when it is valid, else the default (what the app
    /// applies: a bad value keeps the default, with a diagnostic).
    public func effectiveValue(in root: JSONValue) -> JSONValue? {
        if let stored = storedValue(in: root),
           let value = AgentPaneDisplaySettingsSchema.pageValue(id, stored), accepts(value) { return value }
        return defaultValue
    }

    /// Whether the app would apply `value` without a diagnostic. Numbers
    /// outside the range are refused here, although the parser clamps them,
    /// so the window never writes a value that loads with a warning.
    public func accepts(_ value: JSONValue) -> Bool {
        if path == CustomDensitiesSetting().configPath { return CustomDensitiesSetting.accepts(value) }
        if path == ChatSettings.rootsPath {
            guard let items = value.arrayValue else { return false }
            let validator = ChatRootValidator()
            return items.allSatisfy { $0.stringValue.map { validator.refusal($0) == nil } ?? false }
        }
        switch kind {
        case .choice(let choices):
            if path == BackdropSelectionSetting().configPath { return BackdropSelectionSetting.accepts(value) }
            return value.stringValue.map { text in choices.contains { $0.value == text } } ?? false
        case .choiceOrNumber(let choices, let number):
            if let text = value.stringValue { return choices.contains { $0.value == text } }
            return value.doubleValue.map { number.range.contains($0) } ?? false
        case .choiceOrURL(let choices, let urlKey):
            if let text = value.stringValue { return choices.contains { $0.value == text } }
            guard let members = value.objectValue, members.count == 1, let text = members[urlKey]?.stringValue else { return false }
            return Self.httpOrigin(text) != nil
        case .toggle:
            return value.boolValue != nil
        case .number(let number):
            guard let double = value.doubleValue, double.isFinite else { return false }
            return number.range.contains(double)
        case .color:
            return value.stringValue.map(Self.isHexColor) ?? false
        case .sound, .text:
            return value.stringValue != nil
        case .url:
            if BrowserOmnibarSetting.templatePaths.contains(path) { return value.stringValue.map(BrowserOmnibarSetting.isSearchTemplate) ?? false }
            return value.stringValue.map { $0.isEmpty || BrowserNewTabPage.url(from: $0) != nil } ?? false
        case .hostList:
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { $0.stringValue != nil }
        case .folderList:
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { $0.stringValue.map { $0.hasPrefix("/") || $0.hasPrefix("~/") } ?? false }
        case .timeRange:
            guard case .object(let members) = value else { return false }
            return members["start"]?.stringValue.flatMap(QuietHours.minutes) != nil
                && members["end"]?.stringValue.flatMap(QuietHours.minutes) != nil
        case .theme:
            if path == ChromeThemeSetting().configPath { return value.stringValue.map(ChromeThemeSetting().isValid) ?? false }
            return value.stringValue.map(AppThemeSetting().isValid) ?? false
        case .fontFamily:
            return value.stringValue.map(TerminalFontSetting().isValidFamily) ?? false
        case .numberList(let number):
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { item in item.doubleValue.map { $0.isFinite && number.range.contains($0) } ?? false }
        case .stringMap:
            guard case .object(let members) = value else { return false }
            return members.values.allSatisfy { $0.stringValue != nil }
        case .soundRules:
            guard case .object(let members) = value else { return false }
            return members.values.allSatisfy(NotificationSoundRule.accepts)
        case .stringList:
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { $0.stringValue.map { !$0.isEmpty } ?? false }
        case .orderedChoices(let choices), .choiceSet(let choices):
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { item in item.stringValue.map { text in choices.contains { $0.value == text } } ?? false }
        }
    }

    /// Whether the key differs from its default (the row shows Reset).
    public func isCustomized(in root: JSONValue) -> Bool {
        guard let stored = storedValue(in: root) else { return false }
        return stored != defaultValue
    }

    /// The value a toggle flips to: the opposite of what applies now, so a
    /// setting whose default is on turns off on its first toggle.
    public func toggledValue(in root: JSONValue) -> Bool? {
        guard kind == .toggle else { return nil }
        return !(effectiveValue(in: root)?.boolValue ?? false)
    }

    /// `text` as an origin (`scheme://host[:port]`, scheme and host lowercased)
    /// when it is an http or https address with a host and nothing else: no user
    /// info, no path other than "/", no query, no fragment. The same rule as
    /// cmux-config `is_http_origin` and the Settings page's `httpOrigin`.
    static func httpOrigin(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), !text.contains("?"), !text.contains("#"), !text.contains("@"),
              var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.scheme = scheme
        components.path = ""
        components.percentEncodedHost = components.percentEncodedHost?.lowercased()
        return components.url
    }

    static func isHexColor(_ text: String) -> Bool {
        let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        return (digits.count == 6 || digits.count == 8) && digits.allSatisfy(\.isHexDigit)
    }
}
