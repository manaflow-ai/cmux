public import Foundation

extension CEFTab: BrowserURLSaving {
    /// Save Link As…, Save Image As…: downloads `url` with this tab's session
    /// into the chosen file (`CEFDownloads`).
    public func save(_ url: URL, to destination: URL) { _ = browserID.map { runtime.downloads.save(url, to: destination, browser: $0) } }
}
