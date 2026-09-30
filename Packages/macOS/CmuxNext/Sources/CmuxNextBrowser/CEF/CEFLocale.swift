import Foundation

/// The embedded Chromium's UI locale (`CefSettings.locale`) and its
/// Accept-Language list (`accept_language_list`, the `intl.accept_languages`
/// preference, `navigator.languages`).
nonisolated struct CEFLocale: Equatable, Sendable {
    /// Chromium locale name, for example `en-US`, `ja` or `zh-TW`.
    var locale: String
    /// Comma-separated language tags without spaces.
    var acceptLanguages: String

    /// Not derived yet: CEF picks its own defaults.
    static func resolve(preferredLanguages: [String], available: Set<String>) -> CEFLocale {
        CEFLocale(locale: "", acceptLanguages: "")
    }

    /// Chromium locale names of the `.lproj` directories in the framework's
    /// Resources directory.
    static func available(lprojNames: [String]) -> Set<String> {
        []
    }
}
