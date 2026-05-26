import Foundation

enum L10n {
    static func string(_ key: String, defaultValue: String) -> String {
        NSLocalizedString(key, bundle: .module, value: defaultValue, comment: "")
    }
}

public enum BrowserLocalizedString {
    public static var appName: String {
        L10n.string("app.name", defaultValue: "minimal-browser")
    }
}
