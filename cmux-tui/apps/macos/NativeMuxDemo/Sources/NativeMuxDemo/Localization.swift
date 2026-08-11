import Foundation
import SwiftUI

// Safe because Bundle localization lookup is thread-safe and this wrapper
// never mutates the retained bundle after initialization.
private final class LocalizationBundle: @unchecked Sendable {
    let value: Bundle

    init(_ value: Bundle) {
        self.value = value
    }
}

struct Localization: Sendable {
    private let resolve: @Sendable (_ key: String, _ fallback: String) -> String
    let locale: Locale

    static let fallback = Localization(
        locale: Locale(identifier: "en_US_POSIX"),
        resolve: { _, fallback in fallback }
    )

    init(bundle: Bundle, locale: Locale) {
        let bundle = LocalizationBundle(bundle)
        self.locale = locale
        resolve = { key, fallback in
            NSLocalizedString(key, bundle: bundle.value, value: fallback, comment: "")
        }
    }

    init(
        locale: Locale,
        resolve: @escaping @Sendable (_ key: String, _ fallback: String) -> String
    ) {
        self.locale = locale
        self.resolve = resolve
    }

    func text(_ key: String, _ fallback: String) -> String {
        resolve(key, fallback)
    }

    func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback), locale: locale, arguments: arguments)
    }
}

private struct LocalizationEnvironmentKey: EnvironmentKey {
    static let defaultValue = Localization.fallback
}

extension EnvironmentValues {
    var localization: Localization {
        get { self[LocalizationEnvironmentKey.self] }
        set { self[LocalizationEnvironmentKey.self] = newValue }
    }
}
