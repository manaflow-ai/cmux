import CmuxNextBrowser
import Foundation
import Observation
import os

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
    func add(_ item: BrowserDownload, tab key: String, notice: @escaping (String) -> Void) {
        guard !items.contains(where: { $0 === item }) else { return }
        items.append(item)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        logger.notice("download \(item.id, privacy: .public) started in tab \(key, privacy: .public)")
        item.onFinish { [weak self] item in
            self?.finished(item, notice: notice)
        }
    }

    private func finished(_ item: BrowserDownload, notice: (String) -> Void) {
        logger.notice("download \(item.id, privacy: .public) ended: \(String(describing: item.status), privacy: .public) bytes=\(item.receivedBytes) fraction=\(item.fraction ?? -1)")
        switch item.status {
        case .finished: notice(BrowserHitStrings.downloadFinished(item.filename))
        case .failed: notice(BrowserHitStrings.downloadFailed(item.filename))
        case .cancelled, .inProgress, .blocked: break
        }
    }
}
