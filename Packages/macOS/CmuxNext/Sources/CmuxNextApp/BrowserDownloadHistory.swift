import CmuxNextBrowser
import Darwin
import Foundation
import os

/// The ended downloads of the Downloads list, in a small app-local file, so
/// the list a relaunch shows keeps them, as Chrome's does (cx-d0d.72): each
/// row's name, source, file, how it ended and its size. A download of an
/// incognito tab is never written; one still running is not either.
final class BrowserDownloadHistory {
    private let url: URL
    private var written: [Row]?
    /// The latest write; the next one waits for it, so writes land in order.
    private var lastWrite: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "downloads")

    init(url: URL) {
        self.url = url
    }

    /// `<Application Support>/<bundle id>/downloads.json`.
    static func forApplication(bundleIdentifier: String?) -> BrowserDownloadHistory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return BrowserDownloadHistory(url: support.appending(path: bundle).appending(path: "downloads.json"))
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

    /// The rows the last run kept, oldest first (read off the main thread).
    func load() async -> [Row] {
        let url = url
        return await Task.detached(priority: .userInitiated) {
            // concurrency-allow: runs in a detached task, off the main actor
            try? Self.secureStorage(at: url)
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [Row]() }
            return document.downloads
        }.value
    }

    /// Records `rows` when they changed (written off the main thread).
    func record(_ rows: [Row]) {
        guard rows != written else { return }
        written = rows
        let url = url, logger = logger
        let data = try? JSONEncoder().encode(Document(downloads: rows))
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                if let data, !rows.isEmpty {
                    try Self.secureStorage(at: url)
                    try Self.writePrivate(data, to: url)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                logger.error("downloads list write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits until the latest queued persistence operation has finished.
    func waitForPendingWrites() async {
        await lastWrite?.value
    }

    /// Prepares the replacement privately before publishing it at `url`, so interruption cannot
    /// leave the destination at Foundation's default file mode between an atomic rename and chmod.
    nonisolated private static func writePrivate(_ data: Data, to url: URL) throws {
        let files = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try temporary.withUnsafeFileSystemRepresentation { source in
            try url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { throw CocoaError(.fileWriteInvalidFileName) }
                guard Darwin.rename(source, destination) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    /// Browser metadata belongs only to this account. Tightens an existing install as well as a
    /// new one; `writePrivate` separately prepares replacements before publishing them.
    nonisolated private static func secureStorage(at url: URL) throws {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if files.fileExists(atPath: url.path) {
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
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
