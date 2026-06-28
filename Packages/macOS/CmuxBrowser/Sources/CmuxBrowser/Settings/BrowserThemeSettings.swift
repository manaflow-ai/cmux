public import Foundation
public import WebKit
internal import AppKit
public import CmuxSettings

/// Resolves and applies the persisted web-content appearance for the cmux
/// browser.
///
/// The mode is persisted in `UserDefaults` under ``modeKey`` as a
/// ``BrowserThemeMode`` raw value. ``mode(defaults:)`` reads it, falling back to
/// ``defaultMode`` and one-time-migrating the legacy boolean toggle stored under
/// ``legacyForcedDarkModeEnabledKey`` (writing the migrated value back to
/// ``modeKey``). ``mode(for:)`` decodes a raw string in isolation, and
/// ``apply(_:to:)`` maps a mode onto a `WKWebView`'s effective appearance.
///
/// Static members only: a wire-affecting `UserDefaults` key (plus the legacy
/// migration key), default mode constant, stateless resolution over injected
/// defaults or a raw string, and a pure mapping of a mode onto a web view, so
/// there is no per-instance state to hold.
/// lint:allow namespace-type — wire-affecting defaults keys plus stateless
/// theme resolution/application, no per-instance state (no-namespace-enum carve-out).
public struct BrowserThemeSettings {
    /// `UserDefaults` key under which the browser theme mode is persisted.
    public static let modeKey = "browserThemeMode"

    /// Legacy `UserDefaults` key for the boolean forced-dark-mode toggle that
    /// predates ``modeKey``; read only to migrate older installs.
    public static let legacyForcedDarkModeEnabledKey = "browserForcedDarkModeEnabled"

    /// The theme mode applied when nothing valid is stored.
    public static let defaultMode: BrowserThemeMode = .system

    /// Decodes a theme mode from a raw stored string.
    ///
    /// - Parameter rawValue: The raw stored value, if any.
    /// - Returns: The decoded mode, or ``defaultMode`` when `rawValue` is `nil`
    ///   or not a valid mode.
    public static func mode(for rawValue: String?) -> BrowserThemeMode {
        guard let rawValue, let mode = BrowserThemeMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    /// The effective theme mode, migrating the legacy boolean toggle on first
    /// read when the new key is unset.
    ///
    /// - Parameter defaults: The defaults to read (and migrate) from.
    /// - Returns: The stored mode, the migrated legacy value, or ``defaultMode``.
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

    /// Applies `mode` to `webView` by setting its effective appearance.
    ///
    /// - Parameters:
    ///   - mode: The theme mode to apply.
    ///   - webView: The web view whose appearance should match `mode`.
    public static func apply(_ mode: BrowserThemeMode, to webView: WKWebView) {
        // Swift 6.1: WKWebView.appearance is @MainActor; this applies theme on the
        // main-thread browser settings path, so assumeIsolated is behavior-preserving.
        MainActor.assumeIsolated {
            switch mode {
            case .system:
                webView.appearance = nil
            case .light:
                webView.appearance = NSAppearance(named: .aqua)
            case .dark:
                webView.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }
}
