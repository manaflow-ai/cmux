import Foundation

enum L10n {
    static func text(_ key: String, _ fallback: String) -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback), locale: .current, arguments: arguments)
    }
}
