import Foundation
import WebKit

/// Downloads of one WebKit tab: WebKit hands a `WKDownload` here, which
/// mirrors it into a `BrowserDownload` for the host (the tab's `.download`
/// intent) and writes it where `BrowserDownloadPolicy` places it (a temporary
/// sibling of the engine-folder file or of the file the person chose, moved
/// into place when it completes). The tab owns this (`WebKitTab.downloads`).
@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    private weak var tab: WebKitTab?
    private var items: [ObjectIdentifier: BrowserDownload] = [:]
    /// Files the person chose for a download (Save Link As…), by download.
    private var chosenDestinations: [ObjectIdentifier: URL] = [:]

    init(tab: WebKitTab) {
        self.tab = tab
    }

    /// Takes `download` over; `chosen` is the file the person picked, if any.
    func register(_ download: WKDownload, source: URL?, chosen: URL? = nil) {
        guard let tab else { return download.cancel(nil) }
        let item = BrowserDownload(sourceURL: source, filename: source?.lastPathComponent ?? "download")
        item.cancelHandler = { [weak download] in download?.cancel(nil) }
        items[ObjectIdentifier(download)] = item
        if let chosen { chosenDestinations[ObjectIdentifier(download)] = chosen }
        download.delegate = self
        let progress = download.progress
        tab.observations.append(progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in item?.fraction = fraction }
        })
        tab.emit(.download(item))
    }

    private func finish(_ download: WKDownload, status: BrowserDownload.Status) {
        // `complete` quarantines a finished file (`BrowserDownloadPolicy`).
        items.removeValue(forKey: ObjectIdentifier(download))?.complete(status)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let chosen = chosenDestinations.removeValue(forKey: ObjectIdentifier(download))
        let directory = tab?.downloadsDirectory ?? DownloadDestination.defaultDirectory
        // The chosen file (the save panel already asked before replacing
        // it) stays until the download completes; nil cancels the download.
        guard let placement = BrowserDownloadPolicy.place(chosen: chosen, suggestedFilename: suggestedFilename,
                                                          directory: directory) else {
            // No free file name: the download fails (not cancels), as in Chromium.
            finish(download, status: .failed("no free file name"))
            return nil
        }
        guard let item = items[ObjectIdentifier(download)] else {
            placement.discard()
            return nil
        }
        item.filename = placement.finalURL.lastPathComponent
        item.destination = placement.finalURL
        item.placement = placement
        return placement.temporaryURL
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, status: .finished)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let ns = error as NSError
        let cancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        finish(download, status: cancelled ? .cancelled : .failed(ns.localizedDescription))
    }
}
