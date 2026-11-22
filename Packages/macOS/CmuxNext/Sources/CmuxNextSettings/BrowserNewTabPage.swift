public import Foundation

/// `browser.newTabPage` in cmux.json: the page a new browser tab opens when
/// nothing asked for a page (New Browser Tab, the "+" menu, a new browser
/// workspace). Empty or absent opens a blank page. A value without a scheme
/// gets https (`example.com` opens `https://example.com`).
public nonisolated enum BrowserNewTabPage {
    public static let configPath = ["browser", "newTabPage"]
    public static let fallback = ""

    /// The address for `text`, or nil when it is not a web, file or about address.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "file", "about"].contains(scheme) ? url : nil
        }
        guard trimmed.contains("."), let url = URL(string: "https://" + trimmed), url.host() != nil else { return nil }
        return url
    }

    /// A missing or empty key is a blank page with no diagnostic; a bad
    /// value is a blank page plus a diagnostic.
    static func parse(_ root: JSONValue) -> (URL?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue else {
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "browser.newTabPage", message: "expected a web address or \"\""))
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return (nil, nil) }
        guard let url = url(from: text) else {
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "browser.newTabPage", message: "expected a web address or \"\""))
        }
        return (url, nil)
    }
}
