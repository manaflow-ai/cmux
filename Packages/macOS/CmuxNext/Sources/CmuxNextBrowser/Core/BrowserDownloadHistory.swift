package import Foundation
import os

/// The ended downloads of the Downloads list, in a small app-local file, so
/// the list a relaunch shows keeps them, as Chrome's does (cx-d0d.72): each
/// row's name, source, file, how it ended and its size. A download of an
/// incognito tab is never written; one still running is not either.
package final class BrowserDownloadHistory {
    private let storage: any BrowserDownloadHistoryStoring
    private var written: [Row]?
    /// The latest write; the next one waits for it, so writes land in order.
    private var lastWrite: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "downloads")

    package init(url: URL) {
        storage = BrowserDownloadHistoryStorage(url: url)
    }

    package init(storage: any BrowserDownloadHistoryStoring) {
        self.storage = storage
    }

    /// One ended download.
    package nonisolated struct Row: Codable, Equatable, Sendable {
        package var filename: String
        package var source: String?
        package var destination: String?
        /// finished, failed, cancelled or blocked.
        package var status: String
        /// Why it failed or was blocked.
        package var reason: String?
        package var received: Int64
        package var total: Int64?
    }

    nonisolated private struct Document: Codable, Sendable {
        var downloads: [Row]
    }

    /// The rows the last run kept, oldest first (read off the main thread).
    package func load() async -> [Row] {
        let storage = storage
        return await Task.detached(priority: .userInitiated) {
            // concurrency-allow: runs in a detached task, off the main actor
            guard let data = try? storage.read(),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [Row]() }
            return document.downloads
        }.value
    }

    /// Records `rows` when they changed (written off the main thread).
    package func record(_ rows: [Row]) {
        guard rows != written else { return }
        written = rows
        let storage = storage, logger = logger
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            // concurrency-allow: runs in a detached task, off the main actor
            let data = try? JSONEncoder().encode(Document(downloads: rows))
            do {
                if let data, !rows.isEmpty {
                    try storage.write(data)
                } else {
                    try storage.remove()
                }
            } catch {
                logger.error("downloads list write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits until the latest queued persistence operation has finished.
    package func waitForPendingWrites() async {
        await lastWrite?.value
    }

}

extension BrowserDownloadHistory.Row {
    /// `item` as kept; nil while it runs.
    package init?(_ item: BrowserDownload) {
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
    package var download: BrowserDownload? {
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
