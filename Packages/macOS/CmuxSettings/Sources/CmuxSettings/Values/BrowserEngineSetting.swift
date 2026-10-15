import Foundation

/// The engine new browser tabs open with (`browser.engine`).
///
/// Chromium is used only when the app includes the Chromium runtime; a tab
/// that wanted Chromium opens in WebKit otherwise and says why.
public enum BrowserEngineSetting: String, CaseIterable, Sendable, SettingCodable {
    /// Apple WebKit, the default.
    case webkit
    /// Chromium, through the runtime bundled with the app.
    case chromium
}
