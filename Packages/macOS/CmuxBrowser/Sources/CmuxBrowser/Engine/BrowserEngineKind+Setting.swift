public import CmuxSettings
public import Foundation

extension BrowserEngineKind {
    /// The engine a `browser.engine` setting value names.
    /// - Parameter setting: The setting value.
    public init(setting: BrowserEngineSetting) {
        switch setting {
        case .webkit: self = .webkit
        case .chromium: self = .chromium
        }
    }

    /// The configured `browser.engine`, WebKit when unset or unreadable.
    /// - Parameter defaults: The defaults domain holding cmux settings.
    /// - Returns: The engine new browser panels want.
    public static func configured(defaults: UserDefaults) -> BrowserEngineKind {
        let key = SettingCatalog().browser.engine
        guard let raw = defaults.string(forKey: key.userDefaultsKey),
              let setting = BrowserEngineSetting(rawValue: raw) else {
            return BrowserEngineKind(setting: key.defaultValue)
        }
        return BrowserEngineKind(setting: setting)
    }
}
