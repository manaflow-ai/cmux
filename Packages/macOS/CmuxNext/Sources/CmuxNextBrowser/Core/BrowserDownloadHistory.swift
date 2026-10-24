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

    /// `<Application Support>/<bundle id>/downloads.json`.
    package static func forApplication(bundleIdentifier: String?) -> BrowserDownloadHistory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return BrowserDownloadHistory(storage: BrowserDownloadHistoryStorage(
            url: support.appending(path: bundle).appending(path: "downloads.json")
        ))
    }

    /// One ended download.
    nonisolated package struct Row: Codable, Equatable, Sendable {
        package var filename: String
        package var source: String?
        package var destination: String?
        /// finished, failed, cancelled or blocked.
        package var status: String
        /// Why it failed or was blocked.
        package var reason: String?
        package var received: Int64
        package var total: Int64?

        /// Every field, as the synthesized memberwise initializer had them (optionals default to nil).
        package init(filename: String, source: String? = nil, destination: String? = nil, status: String,
                     reason: String? = nil, received: Int64, total: Int64? = nil) {
            self.filename = filename
            self.source = source
            self.destination = destination
            self.status = status
            self.reason = reason
            self.received = received
            self.total = total
        }
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
        let data = try? JSONEncoder().encode(Document(downloads: rows))
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
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
