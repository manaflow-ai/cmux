import Foundation

enum L10n {
    private static let bundle: Bundle = {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("TerminalBytesDemo_TerminalBytesDemo.bundle")
        let packaged = packagedURL.flatMap { Bundle(url: $0) }
        return packaged ?? Bundle.module
    }()

    static func text(_ key: String, _ fallback: String) -> String {
        bundle.localizedString(forKey: key, value: fallback, table: nil)
    }
}
