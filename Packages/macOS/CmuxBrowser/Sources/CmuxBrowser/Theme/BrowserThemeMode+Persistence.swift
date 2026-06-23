public import Foundation
public import WebKit
import AppKit
public import CmuxSettings

/// Persistence keys, defaults resolution, legacy migration, and WebKit
/// appearance application for ``BrowserThemeMode``.
///
/// ``BrowserThemeMode`` is the user-selected web-content appearance owned by
/// `CmuxSettings`. This extension folds the browser-specific behavior that used
/// to live in the app-side `BrowserThemeSettings` namespace onto the type
/// itself: the `UserDefaults` key for the persisted mode, the legacy
/// forced-dark-mode bool key, default resolution, the one-time migration of the
/// legacy bool toggle, and the `WKWebView` appearance application.
extension BrowserThemeMode {
    /// `UserDefaults` key storing the persisted ``BrowserThemeMode`` raw value.
    public static let modeKey = "browserThemeMode"

    /// Legacy `UserDefaults` key for the boolean forced-dark-mode toggle that
    /// preceded the three-way ``BrowserThemeMode``. Migrated once into ``modeKey``.
    public static let legacyForcedDarkModeEnabledKey = "browserForcedDarkModeEnabled"

    /// The mode used when nothing is persisted.
    public static let defaultMode: BrowserThemeMode = .system

    /// Resolves a stored raw value into a ``BrowserThemeMode``, falling back to
    /// ``defaultMode`` when the value is missing or unrecognized.
    public static func mode(for rawValue: String?) -> BrowserThemeMode {
        guard let rawValue, let mode = BrowserThemeMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    /// Resolves the persisted ``BrowserThemeMode`` from `defaults`, migrating the
    /// legacy boolean forced-dark-mode toggle into ``modeKey`` the first time the
    /// new key is unset.
    public static func mode(defaults: UserDefaults = .standard) -> BrowserThemeMode {
        let resolvedMode = mode(for: defaults.string(forKey: modeKey))
        if defaults.string(forKey: modeKey) != nil {
            return resolvedMode
        }

        // Migrate the legacy bool toggle only when the new mode key is unset.
        if defaults.object(forKey: legacyForcedDarkModeEnabledKey) != nil {
            let migratedMode: BrowserThemeMode = defaults.bool(forKey: legacyForcedDarkModeEnabledKey) ? .dark : .system
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return migratedMode
        }

        return defaultMode
    }

    /// Applies this mode's appearance to `webView`. `.system` clears the
    /// override so the web content tracks the system appearance.
    public func apply(to webView: WKWebView) {
        switch self {
        case .system:
            webView.appearance = nil
        case .light:
            webView.appearance = NSAppearance(named: .aqua)
        case .dark:
            webView.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
