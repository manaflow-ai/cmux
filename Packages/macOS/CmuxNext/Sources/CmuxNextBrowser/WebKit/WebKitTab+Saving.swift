public import Foundation

extension WebKitTab: BrowserURLSaving {
    /// Save Link As…, Save Image As…: downloads `url` with the page's session
    /// into `destination`, a file the person chose (`WebKitDownloads`).
    public func save(_ url: URL, to destination: URL) {
        BrowserDownload.startSave(url, to: destination, start: {
            webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
                guard let self else { return download.cancel(nil) }
                downloads.register(download, source: url, chosen: destination)
            }
            return true
        }, deliver: { emit(.download($0)) })
    }
}
