import Foundation

/// User-selected web-content appearance for the cmux browser.
public enum BrowserThemeMode: String, CaseIterable, Sendable, SettingCodable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }
}
