public import Foundation

/// A page that downloads an address into a file the person chose, with its
/// own session (cookies included): WebKit through `WKDownload`, Chromium
/// through the shim's downloads (`CEFDownloads`). Both start through
/// `BrowserDownload.startSave`, so a save that cannot start is never silent.
public protocol BrowserURLSaving: AnyObject {
    func save(_ url: URL, to destination: URL)
}

extension BrowserDownload {
    /// The addresses Save Link As… and Save Image As… download: http, https,
    /// data, blob; never file: or other local or internal schemes.
    static let savableSchemes: Set<String> = ["http", "https", "data", "blob"]

    /// Save Link As…, Save Image As… on either engine. `start` begins the
    /// engine's own download of `url` into `destination` and returns false
    /// when it could not. A save that does not start (an address that is not
    /// a web address, no page, the engine refused) becomes a download that
    /// failed at once, handed to `deliver` (the tab's `.download` intent), so
    /// the App's downloads list shows the failure notice it shows for any
    /// failed download.
    static func startSave(_ url: URL, to destination: URL, start: () -> Bool, deliver: (BrowserDownload) -> Void) {
        guard savableSchemes.contains(url.scheme?.lowercased() ?? "") else {
            return failSave(url, to: destination, reason: "not a web address", deliver: deliver)
        }
        guard start() else { return failSave(url, to: destination, reason: "not started", deliver: deliver) }
    }

    private static func failSave(_ url: URL, to destination: URL, reason: String, deliver: (BrowserDownload) -> Void) {
        let item = BrowserDownload(sourceURL: url, filename: destination.lastPathComponent)
        deliver(item)
        item.complete(.failed(reason))
    }
}
