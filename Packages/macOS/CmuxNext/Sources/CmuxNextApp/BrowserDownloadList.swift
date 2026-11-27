import CmuxNextBrowser
import Foundation
import Observation
import os

/// The notice shown over a tab when a download ends: its line, and for a
/// download a site's automatic-downloads setting blocked, that site, whose
/// Site settings change the choice (the notice's button).
struct BrowserDownloadNotice: Equatable {
    var text: String
    var siteSettingsOrigin: String?
    /// The download finished: the Downloads popup shows it instead when it can.
    var finished = false
}

/// The App's one list of downloads, for both engines: every `.download`
/// intent (WebKit's `WKDownload`, Chromium's shim downloads) lands here. It
/// logs each start and end and shows a notice over the tab when a download
/// finishes or fails. The toolbar's Downloads popup lists `items`
/// (`BrowserDownloadsPopup`). Ended downloads are kept across a relaunch
/// (`history`), except an incognito tab's.
@Observable
final class BrowserDownloadList {
    /// Newest last; at most `limit`.
    private(set) var items: [BrowserDownload] = []
    static let limit = 100
    /// The newest download a site's automatic-downloads setting blocked:
    /// that site and the tab it came from. `browser.download.openBlocked
    /// SiteSettings` opens that site's Site settings from it.
    private(set) var latestBlocked: (site: String, tab: String)?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "downloads")
    /// Each new download and its tab: the browser host reports it to an
    /// agent driving that tab (`download.started`, then `download.finished`).
    var onDownload: ((BrowserDownload, String) -> Void)?
    /// Where ended downloads are kept; nil keeps none.
    @ObservationIgnored var history: BrowserDownloadHistory?
    /// Downloads never kept: an incognito tab's.
    @ObservationIgnored private var unkept: Set<ObjectIdentifier> = []
    /// True once the kept rows are back: no write replaces them before.
    @ObservationIgnored private var restored = false
    /// Clear ran before the kept rows were back: they stay cleared.
    @ObservationIgnored private var clearedBeforeRestore = false
    /// The tab each download of this run came from. Rows restored from an
    /// earlier run have none, so they never show a tab's Downloads button.
    private var origins: [ObjectIdentifier: String] = [:]
    /// Agent waits on these downloads (`browser.page.download.wait`).
    @ObservationIgnored let waits = BrowserDownloadWaits()

    /// Adds `item` (from tab `key`); `notice` shows a line over that tab.
    /// With `keep` false (an incognito tab) it is never written down.
    func add(_ item: BrowserDownload, tab key: String, keep: Bool = true, notice: @escaping (BrowserDownloadNotice) -> Void) {
        guard !items.contains(where: { $0 === item }) else { return }
        if !keep { unkept.insert(ObjectIdentifier(item)) }
        items.append(item)
        origins[ObjectIdentifier(item)] = key
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        pruneOrigins()
        logger.notice("download \(item.id, privacy: .public) started in tab \(key, privacy: .public)")
        onDownload?(item, key)
        waits.started(item, tab: key)
        item.onFinish { [weak self] item in
            if case .blocked = item.status, let site = item.blockedSite { self?.latestBlocked = (site, key) }
            self?.finished(item, notice: notice)
        }
    }

    /// The tab `item` came from, when it started in this run.
    func origin(of item: BrowserDownload) -> String? { origins[ObjectIdentifier(item)] }

    /// True while a download tab `key` started in this run is still in progress (the page
    /// does not hibernate meanwhile).
    func isDownloading(tab key: String) -> Bool {
        items.contains { $0.status == .inProgress && origins[ObjectIdentifier($0)] == key }
    }

    /// What tab `key`'s Downloads button shows; read while it renders, so
    /// it redraws as downloads start and end. The button counts only the
    /// downloads that tab started in this run (a person who downloaded
    /// nothing from the page sees no button), and is drawn active while any
    /// download runs, so a running one stays reachable from every tab. The
    /// menu it opens still lists every download, kept ones included.
    func toolbarSummary(forTab key: String) -> BrowserToolbarDownloads {
        let running = items.filter { $0.status == .inProgress }
        return BrowserToolbarDownloads(count: items.filter { origins[ObjectIdentifier($0)] == key }.count,
                                       inProgress: !running.isEmpty, progress: Self.progress(of: running))
    }

    /// The running downloads' bytes over their sizes, in whole percent
    /// steps (so the toolbar redraws at most 100 times per download); nil
    /// when none runs or one has no known size.
    static func progress(of running: [BrowserDownload]) -> Double? {
        guard !running.isEmpty else { return nil }
        var received: Int64 = 0, total: Int64 = 0
        for item in running {
            guard let size = item.totalBytes, size > 0 else { return nil }
            received += min(item.receivedBytes, size)
            total += size
        }
        return (Double(received) / Double(total) * 100).rounded(.down) / 100
    }

    /// Forgets the origins of rows no longer listed (dropped past `limit`,
    /// cleared, retried).
    private func pruneOrigins() {
        let listed = Set(items.map(ObjectIdentifier.init))
        if origins.keys.contains(where: { !listed.contains($0) }) { origins = origins.filter { listed.contains($0.key) } }
        waits.keep(only: listed)
    }

    /// Retry in the Downloads menu: starts `item` again; the new download
    /// takes its row, as in Chrome. False when it could not start.
    @discardableResult
    func retry(_ item: BrowserDownload) -> Bool {
        guard item.retry() else { return false }
        items.removeAll { $0 === item }
        pruneOrigins()
        save()
        return true
    }

    /// Drops every download that ended (Clear in the Downloads menu); the
    /// files stay where they are.
    func clearEnded() {
        items.removeAll { $0.status != .inProgress }
        pruneOrigins()
        if !restored { clearedBeforeRestore = true }
        save()
    }

    /// Puts back the downloads the last run kept, before this run's.
    func restore() async {
        guard let history, !restored else { return }
        let loaded = await history.load()
        let kept = clearedBeforeRestore ? [] : loaded.compactMap(\.download)
        restored = true
        items = kept + items
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        save()
    }

    /// Writes the ended downloads down (`history`).
    private func save() {
        guard let history, restored else { return }
        unkept = unkept.filter { id in items.contains { ObjectIdentifier($0) == id } }
        history.record(items.filter { !unkept.contains(ObjectIdentifier($0)) }.compactMap(BrowserDownloadHistory.Row.init))
    }

    private func finished(_ item: BrowserDownload, notice: (BrowserDownloadNotice) -> Void) {
        logger.notice("download \(item.id, privacy: .public) ended: \(String(describing: item.status), privacy: .public) bytes=\(item.receivedBytes) fraction=\(item.fraction ?? -1)")
        if let line = Self.notice(for: item) { notice(line) }
        save()
    }

    /// The notice for an ended download; nil when none shows (cancelled).
    static func notice(for item: BrowserDownload) -> BrowserDownloadNotice? {
        switch item.status {
        case .finished: BrowserDownloadNotice(text: BrowserHitStrings.downloadFinished(item.filename), finished: true)
        case .failed: BrowserDownloadNotice(text: BrowserHitStrings.downloadFailed(item.filename))
        case .blocked: BrowserDownloadNotice(text: BrowserHitStrings.downloadBlocked(item.filename), siteSettingsOrigin: item.blockedSite)
        case .cancelled, .inProgress: nil
        }
    }
}
