public import Foundation
public import WebKit

/// Downloads: WebKit hands a `WKDownload` to the tab, which mirrors it into a
/// `BrowserDownload` for the host and writes it where `BrowserDownloadPolicy`
/// places it (a temporary sibling of the engine-folder file or of the file
/// the person chose, moved into place when it completes).
extension WebKitTab: WKDownloadDelegate, BrowserURLSaving {
    func register(_ download: WKDownload, source: URL?) {
        let item = BrowserDownload(sourceURL: source, filename: source?.lastPathComponent ?? "download")
        item.cancelHandler = { [weak download] in download?.cancel(nil) }
        downloads[ObjectIdentifier(download)] = item
        download.delegate = self
        let progress = download.progress
        observations.append(progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in item?.fraction = fraction }
        })
        emit(.download(item))
    }

    /// Downloads `url` with the page's session into `destination`, a file
    /// the person chose (Save Link As…, Save Image As…).
    public func save(_ url: URL, to destination: URL) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return download.cancel(nil) }
            self.chosenDestinations[ObjectIdentifier(download)] = destination
            self.register(download, source: url)
        }
    }

    func download(for download: WKDownload) -> BrowserDownload? {
        downloads[ObjectIdentifier(download)]
    }

    func finishDownload(_ download: WKDownload, status: BrowserDownload.Status) {
        // `complete` quarantines a finished file (`BrowserDownloadPolicy`).
        downloads.removeValue(forKey: ObjectIdentifier(download))?.complete(status)
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let chosen = chosenDestinations.removeValue(forKey: ObjectIdentifier(download))
        // The chosen file (the save panel already asked before replacing
        // it) stays until the download completes; nil cancels the download.
        guard let placement = BrowserDownloadPolicy.place(chosen: chosen, suggestedFilename: suggestedFilename,
                                                          directory: downloadsDirectory) else { return nil }
        guard let item = self.download(for: download) else {
            placement.discard()
            return nil
        }
        item.filename = placement.finalURL.lastPathComponent
        item.destination = placement.finalURL
        item.placement = placement
        return placement.temporaryURL
    }

    public func downloadDidFinish(_ download: WKDownload) {
        finishDownload(download, status: .finished)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let ns = error as NSError
        let cancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        finishDownload(download, status: cancelled ? .cancelled : .failed(ns.localizedDescription))
    }
}
