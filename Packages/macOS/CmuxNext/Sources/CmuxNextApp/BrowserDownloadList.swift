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
}

/// The App's one list of downloads, for both engines: every `.download`
/// intent (WebKit's `WKDownload`, Chromium's shim downloads) lands here. It
/// logs each start and end and shows a notice over the tab when a download
/// finishes or fails. A downloads window can list `items` later.
@Observable
final class BrowserDownloadList {
    /// Newest last; at most `limit`.
    private(set) var items: [BrowserDownload] = []
    static let limit = 100
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "downloads")

    /// Adds `item` (from tab `key`); `notice` shows a line over that tab.
    func add(_ item: BrowserDownload, tab key: String, notice: @escaping (BrowserDownloadNotice) -> Void) {
        guard !items.contains(where: { $0 === item }) else { return }
        items.append(item)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        logger.notice("download \(item.id, privacy: .public) started in tab \(key, privacy: .public)")
        item.onFinish { [weak self] item in
            self?.finished(item, notice: notice)
        }
    }

    private func finished(_ item: BrowserDownload, notice: (BrowserDownloadNotice) -> Void) {
        logger.notice("download \(item.id, privacy: .public) ended: \(String(describing: item.status), privacy: .public) bytes=\(item.receivedBytes) fraction=\(item.fraction ?? -1)")
        if let line = Self.notice(for: item) { notice(line) }
    }

    /// The notice for an ended download; nil when none shows (cancelled).
    static func notice(for item: BrowserDownload) -> BrowserDownloadNotice? {
        switch item.status {
        case .finished: BrowserDownloadNotice(text: BrowserHitStrings.downloadFinished(item.filename))
        case .failed: BrowserDownloadNotice(text: BrowserHitStrings.downloadFailed(item.filename))
        case .blocked: BrowserDownloadNotice(text: BrowserHitStrings.downloadBlocked(item.filename))
        case .cancelled, .inProgress: nil
        }
    }
}
