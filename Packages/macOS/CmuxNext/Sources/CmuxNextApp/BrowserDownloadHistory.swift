import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import os

/// The ended downloads of the Downloads list, in a small app-local file, so
/// the list a relaunch shows keeps them, as Chrome's does (cx-d0d.72): each
/// row's name, source, file, how it ended and its size. A download of an
/// incognito tab is never written; one still running is not either.
final class BrowserDownloadHistory {
    private let storage: any BrowserDownloadHistoryStoring
    private var written: [Row]?
    private let work: BackgroundWork
    /// Writes land in the order they were made, on the files lane.
    private let writes: OrderedWrites
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "downloads")

    convenience init(url: URL, work: BackgroundWork) {
        self.init(storage: BrowserDownloadHistoryStorage(url: url), work: work)
    }

    init(storage: any BrowserDownloadHistoryStoring, work: BackgroundWork) {
        self.storage = storage
        self.work = work
        let logger = logger
        writes = OrderedWrites(work: work) { logger.error("downloads list write failed: \(String(describing: $0), privacy: .public)") }
    }

    /// `<Application Support>/<bundle id>/downloads.json`.
    static func forApplication(bundleIdentifier: String?, work: BackgroundWork) -> BrowserDownloadHistory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return BrowserDownloadHistory(storage: BrowserDownloadHistoryStorage(
            url: support.appending(path: bundle).appending(path: "downloads.json")
        ), work: work)
    }

    /// One ended download.
    nonisolated struct Row: Codable, Equatable, Sendable {
        var filename: String
        var source: String?
        var destination: String?
        /// finished, failed, cancelled or blocked.
        var status: String
        /// Why it failed or was blocked.
        var reason: String?
        var received: Int64
        var total: Int64?
    }

    nonisolated private struct Document: Codable, Sendable {
        var downloads: [Row]
    }

    /// The rows the last run kept, oldest first (read on the files lane).
    func load() async -> [Row]? {
        let storage = storage
        // The Downloads list shows them. Nil only when the lanes refused the read (quit shut them down): the
        // file was not read, so the caller must not write over it.
        return try? await work.run(.userVisible, mayBlock: .files) {
            guard let data = try? storage.read(),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [Row]() }
            return document.downloads
        }
    }

    /// Records `rows` when they changed (written on the files lane, in order).
    func record(_ rows: [Row]) {
        guard rows != written else { return }
        written = rows
        let storage = storage
        let data = try? JSONEncoder().encode(Document(downloads: rows))
        writes.enqueue {
            if let data, !rows.isEmpty {
                try storage.write(data)
            } else {
                try storage.remove()
            }
        }
    }

    /// Waits until the latest queued persistence operation has finished.
    func waitForPendingWrites() async {
        await writes.flush()
    }

}

extension BrowserDownloadHistory.Row {
    /// `item` as kept; nil while it runs.
    init?(_ item: BrowserDownload) {
        let (status, reason): (String, String?) = switch item.status {
        case .inProgress: ("", nil)
        case .finished: ("finished", nil)
        case .failed(let why): ("failed", why)
        case .cancelled: ("cancelled", nil)
        case .blocked(let why): ("blocked", why)
        }
        guard !status.isEmpty else { return nil }
        // Only a web link is kept: a data: or blob: source can be megabytes.
        let source = item.sourceURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0.absoluteString : nil }
        self.init(filename: item.filename, source: source,
                  destination: item.destination?.path(percentEncoded: false), status: status, reason: reason,
                  received: item.receivedBytes, total: item.totalBytes)
    }

    /// The list's row for this kept download; nil for one this build cannot read.
    var download: BrowserDownload? {
        let ended: BrowserDownload.Status
        switch status {
        case "finished": ended = .finished
        case "failed": ended = .failed(reason ?? "")
        case "cancelled": ended = .cancelled
        case "blocked": ended = .blocked(reason ?? "")
        default: return nil
        }
        return .ended(sourceURL: source.flatMap(URL.init(string:)), filename: filename,
                      destination: destination.map { URL(filePath: $0) }, status: ended,
                      receivedBytes: received, totalBytes: total)
    }
}
