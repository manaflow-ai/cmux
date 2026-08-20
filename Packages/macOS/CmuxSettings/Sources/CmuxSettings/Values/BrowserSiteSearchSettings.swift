import Foundation

/// Selects how the omnibar activates a site-search shortcut.
public enum BrowserSiteSearchActivationShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
    case tab
    case spaceOrTab
    public var id: String { rawValue }
    public var displayName: String { switch self { case .tab: return String(localized: "settings.browser.siteSearch.keyboard.tab", defaultValue: "Tab"); case .spaceOrTab: return String(localized: "settings.browser.siteSearch.keyboard.spaceOrTab", defaultValue: "Space or Tab") } }
    public var promptText: String { switch self { case .tab: return String(localized: "browser.omnibar.siteSearch.pressTab", defaultValue: "Press Tab to search"); case .spaceOrTab: return String(localized: "browser.omnibar.siteSearch.pressSpaceOrTab", defaultValue: "Press Space or Tab to search") } }
}

extension BrowserSiteSearchActivationShortcut: SettingCodable {}

/// Package-owned site-search settings while preserving the legacy defaults keys.
public struct BrowserSiteSearchSettings: Equatable, Sendable {
    public static let shortcutsKey = "browserSiteSearchShortcuts"
    public static let activationShortcutKey = "browserSiteSearchActivationShortcut"
    public static let defaultShortcutsStorage = "[]"
    public static let defaultActivationShortcut: BrowserSiteSearchActivationShortcut = .tab
    public var shortcuts: [BrowserSiteSearchShortcut]
    public var activationShortcut: BrowserSiteSearchActivationShortcut
    /// Creates settings from decoded values.
    public init(shortcuts: [BrowserSiteSearchShortcut], activationShortcut: BrowserSiteSearchActivationShortcut) { self.shortcuts = shortcuts; self.activationShortcut = activationShortcut }
    /// Creates settings from legacy UserDefaults storage values.
    public init(shortcutsStorage: String?, activationShortcutRaw: String?) { shortcuts = Self.decode(shortcutsStorage); activationShortcut = BrowserSiteSearchActivationShortcut(rawValue: activationShortcutRaw ?? "") ?? .tab }
    public var shortcutsStorage: String { Self.encode(shortcuts) }
    public var activeShortcuts: [BrowserSiteSearchShortcut] { shortcuts.filter { $0.isActive && $0.isValid } }
    public func matchingShortcut(_ value: String) -> BrowserSiteSearchShortcut? { let n = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); guard !n.isEmpty else { return nil }; return activeShortcuts.first { $0.shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == n } }
    public static func encode(_ shortcuts: [BrowserSiteSearchShortcut]) -> String { guard let d = try? JSONEncoder().encode(shortcuts), let s = String(data: d, encoding: .utf8) else { return defaultShortcutsStorage }; return s }
    public static func decode(_ raw: String?) -> [BrowserSiteSearchShortcut] { guard let raw, let d = raw.data(using: .utf8), let result = try? JSONDecoder().decode([BrowserSiteSearchShortcut].self, from: d) else { return [] }; return result }
    public static func current(defaults: UserDefaults = .standard) -> Self { Self(shortcutsStorage: defaults.string(forKey: shortcutsKey), activationShortcutRaw: defaults.string(forKey: activationShortcutKey)) }
    public static func parseManagedShortcuts(_ items: [[String: Any]]) -> [BrowserSiteSearchShortcut] { items.compactMap { item in guard let name = item["name"] as? String, let shortcut = item["shortcut"] as? String, let url = item["urlTemplate"] as? String else { return nil }; let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(); let value = BrowserSiteSearchShortcut(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), shortcut: shortcut.trimmingCharacters(in: .whitespacesAndNewlines), urlTemplate: url.trimmingCharacters(in: .whitespacesAndNewlines), isActive: (item["isActive"] as? Bool) ?? true); return value.isValid ? value : nil } }
}
