import Foundation

extension SettingDescriptor {
    /// The value stored in `root`, or nil when the key is absent. A renamed
    /// key that is absent reads its old key, as the parser does, so Settings
    /// shows the value the app applies.
    public func storedValue(in root: JSONValue) -> JSONValue? {
        root.value(at: path) ?? WorkspaceRowSetting.legacyValue(for: path, in: root)
    }

    /// The stored value when it is valid, else the default (what the app
    /// applies: a bad value keeps the default, with a diagnostic).
    public func effectiveValue(in root: JSONValue) -> JSONValue? {
        if let stored = storedValue(in: root), accepts(stored) { return stored }
        return defaultValue
    }

    /// Whether the app would apply `value` without a diagnostic. Numbers
    /// outside the range are refused here, although the parser clamps them,
    /// so the window never writes a value that loads with a warning.
    public func accepts(_ value: JSONValue) -> Bool {
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
        case .toggle:
            return value.boolValue != nil
        case .number(let number):
            guard let double = value.doubleValue, double.isFinite else { return false }
            return number.range.contains(double)
        case .color:
            return value.stringValue.map(Self.isHexColor) ?? false
        case .sound:
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
        case .stringList:
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { $0.stringValue.map { !$0.isEmpty } ?? false }
        case .orderedChoices(let choices):
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

    static func isHexColor(_ text: String) -> Bool {
        let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        return (digits.count == 6 || digits.count == 8) && digits.allSatisfy(\.isHexDigit)
    }
}
