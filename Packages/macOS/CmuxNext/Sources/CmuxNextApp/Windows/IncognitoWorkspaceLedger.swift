import CmuxNextCompat
import Foundation
import os

/// The workspaces of open incognito windows, in a small app-local file
/// (never in the daemon's personal state), so a run that ends without
/// closing them (a crash, a kill) cannot bring their pages back in a normal
/// window: the next launch closes them. Only workspace ids are written, no
/// URL or title. A clean close or quit closes the workspaces itself. On a
/// daemon with state resources incognito workspaces are ephemeral and the
/// daemon's flag replaces this file (`WindowManager+Ephemeral`); it keeps
/// only incognito workspaces the daemon does not know as such (a tab torn
/// off into a new workspace). It also lists the incognito spaces
/// (spaces-overhaul-DESIGN.md rule 2), which the next launch deletes.
final class IncognitoWorkspaceLedger {
    private let url: URL
    private var written: (workspaces: Set<String>, spaces: Set<String>)?
    /// The latest write; the next one waits for it, so writes land in order.
    private var lastWrite: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "incognito")

    init(url: URL) {
        self.url = url
    }

    /// `<Application Support>/<bundle id>/incognito-workspaces.json`.
    static func forApplication(bundleIdentifier: String?) -> IncognitoWorkspaceLedger {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return IncognitoWorkspaceLedger(url: support.appending(path: bundle).appending(path: "incognito-workspaces.json"))
    }

    nonisolated private struct Document: Codable, Sendable {
        var workspaces: [String]
        /// Incognito space ids; absent in a file an older build wrote.
        var spaces: [String]?
    }

    /// True when the last run left incognito workspaces: the file exists
    /// only while it lists some (an existence check, no read).
    var hasLeftovers: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The ids the last run left (read off the main thread).
    func load() async -> [String] {
        await document()?.workspaces ?? []
    }

    /// The incognito spaces the last run left (read off the main thread).
    func loadSpaces() async -> [String] {
        await document()?.spaces ?? []
    }

    /// The file's document, read off the main thread; nil when there is none.
    private func document() async -> Document? {
        let url = url
        return await Task.detached(priority: .userInitiated) {
            // concurrency-allow: runs in a detached task, off the main actor
            guard let data = try? Data(blockingContentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Document.self, from: data)
        }.value
    }

    /// Records `ids` and the incognito `spaces` when they changed (written off the main thread). Returns the
    /// write, which a caller may await (nil when nothing changed).
    @discardableResult
    func record(_ ids: Set<String>, spaces: Set<String> = []) -> Task<Void, Never>? {
        if let written, written.workspaces == ids, written.spaces == spaces { return nil }
        written = (ids, spaces)
        let url = url, logger = logger
        let empty = ids.isEmpty && spaces.isEmpty
        let data = try? JSONEncoder().encode(Document(workspaces: ids.sorted(), spaces: spaces.isEmpty ? nil : spaces.sorted()))
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                if let data, !empty {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                logger.error("incognito ledger write failed: \(String(describing: error), privacy: .public)")
            }
        }
        return lastWrite
    }
}
