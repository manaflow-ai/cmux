public import Foundation

extension CEFTab: BrowserURLSaving {
    /// Save Link As…, Save Image As…: downloads `url` with this tab's session
    /// into the chosen file (`CEFDownloads`); a tab without a page, or a
    /// download the shim does not start, shows as a failed download.
    public func save(_ url: URL, to destination: URL) {
        BrowserDownload.startSave(url, to: destination, start: {
            guard let browserID else { return false }
            return runtime.downloads.save(url, to: destination, browser: browserID)
        }, deliver: { emit(.download($0)) })
    }
}
