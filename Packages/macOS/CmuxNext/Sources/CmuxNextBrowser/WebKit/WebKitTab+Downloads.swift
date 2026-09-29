public import Foundation
public import WebKit

/// Downloads: WebKit hands a `WKDownload` to the tab, which mirrors it into a
/// `BrowserDownload` for the host and writes it to the engine's folder.
extension WebKitTab: WKDownloadDelegate {
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

    func download(for download: WKDownload) -> BrowserDownload? {
        downloads[ObjectIdentifier(download)]
    }

    func finishDownload(_ download: WKDownload, status: BrowserDownload.Status) {
        guard let item = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if status == .finished { item.fraction = 1 }
        if item.status == .inProgress { item.status = status }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let destination = DownloadDestination.uniqueURL(in: downloadsDirectory, suggestedFilename: suggestedFilename)
        if let item = self.download(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
        }
        return destination
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
