import CmuxNextWakeups
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
    // memory: fixed: one entry per download of this tab the person paused, removed on resume or
    // cancel; resume data is a small plist (URL, validators, partial file path), not the bytes
    // downloaded, and dropping it would lose the download's resume, so it is state, not a cache.
    /// Paused downloads' resume data, by `BrowserDownload.id`.
    private var paused: [UUID: Data] = [:]
    /// Downloads Pause cancelled whose resume data has not come back yet.
    private var pausing: Set<ObjectIdentifier> = []
    /// Each running download's progress, mirrored into its item.
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// The tab's main-thread scheduler: progress and pause answers land as `visible` tasks on it (the downloads list).
    private let mainWork: MainWorkScheduler
    /// The progress task owner, interned once: KVO reports progress per chunk, from any thread.
    private let progressOwner: MainTaskOwner

    init(tab: WebKitTab) {
        self.tab = tab
        mainWork = tab.mainWork
        progressOwner = tab.mainWork.board.owner("WebKitDownloads.progress")
    }

    /// Takes `download` over; `chosen` is the file the person picked, if any.
    func register(_ download: WKDownload, source: URL?, chosen: URL? = nil) {
        guard let tab else { return download.cancel(nil) }
        let item = BrowserDownload(sourceURL: source, filename: source?.lastPathComponent ?? "download", named: false)
        if let chosen { chosenDestinations[ObjectIdentifier(download)] = chosen }
        if let source, ["http", "https"].contains(source.scheme?.lowercased()) {
            // Retry starts it again from this tab, to the file the person chose if they chose one.
            item.retryHandler = { [weak tab] in
                guard let tab else { return false }
                tab.webView.startDownload(using: URLRequest(url: source)) { [weak tab] download in
                    tab?.downloads.register(download, source: source, chosen: chosen)
                }
                return true
            }
        }
        attach(download, to: item)
        tab.emit(.download(item))
    }

    /// Mirrors `download` into `item`: a new download, or a paused one resumed.
    private func attach(_ download: WKDownload, to item: BrowserDownload) {
        items[ObjectIdentifier(download)] = item
        item.cancelHandler = { [weak self, weak download, weak item] in
            if let item { self?.paused.removeValue(forKey: item.id) }
            download?.cancel(nil)
        }
        item.pauseHandler = { [weak self, weak download, weak item] pause in
            guard let self, let item else { return }
            if pause, let download { self.pause(download, item: item) } else if !pause { self.resume(item) }
        }
        download.delegate = self
        let progress = download.progress
        let key = ObjectIdentifier(download)
        let mainWork = mainWork, owner = progressOwner
        // raw-observer-allow: NSProgress reports a download's bytes only through KVO; it is this download's own progress, no window's or app's notice
        progressObservations[key] = progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak item] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            // node-free: the downloads list shows every tab's downloads, a hidden tab's too
            mainWork.postFromAnyThread(.visible, owner: owner) {
                // An update queued before Pause or the end is stale: it would clear the pause.
                guard let self, let item, self.items[key] === item, !self.pausing.contains(key) else { return }
                item.update(received: received, total: total > 0 ? total : nil)
            }
        }
    }

    /// WebKit cannot pause a download: it is cancelled with resume data
    /// (the partial file stays), and Resume starts it again from there.
    /// The download stays listed until the cancel answers: one that
    /// finishes meanwhile still lands (`finish`).
    private func pause(_ download: WKDownload, item: BrowserDownload) {
        let key = ObjectIdentifier(download)
        pausing.insert(key)
        progressObservations.removeValue(forKey: key)?.invalidate()
        item.isPaused = true
        let mainWork = mainWork
        download.cancel { [weak self, weak item] data in
            // node-free: the downloads list shows every tab's downloads, a hidden tab's too
            mainWork.postFromAnyThread(.visible, owner: "WebKitDownloads.pause") {
                guard let self else { return }
                self.pausing.remove(key)
                guard self.items.removeValue(forKey: key) != nil, let item, item.status == .inProgress else { return }
                // A server that cannot resume (no resume data) fails the download.
                guard let data else { return item.complete(.failed("cannot resume")) }
                self.paused[item.id] = data
            }
        }
    }

    private func resume(_ item: BrowserDownload) {
        guard let tab, let data = paused.removeValue(forKey: item.id) else { return }
        item.isPaused = false
        tab.webView.resumeDownload(fromResumeData: data) { [weak self, weak item] download in
            guard let self, let item, item.status == .inProgress else { return download.cancel(nil) }
            self.attach(download, to: item)
        }
    }

    private func finish(_ download: WKDownload, status: BrowserDownload.Status) {
        // The pause's own cancel ends no download.
        if pausing.contains(ObjectIdentifier(download)), status != .finished { return }
        // `complete` quarantines a finished file (`BrowserDownloadPolicy`).
        progressObservations.removeValue(forKey: ObjectIdentifier(download))?.invalidate()
        items.removeValue(forKey: ObjectIdentifier(download))?.complete(status)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        // A resumed download goes on writing its file.
        if let placed = items[ObjectIdentifier(download)]?.placement { return placed.temporaryURL }
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
        item.suggestedFilename = DownloadDestination.sanitizedFilename(suggestedFilename)
        item.filename = placement.finalURL.lastPathComponent
        item.named()
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
