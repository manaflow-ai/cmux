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
/// off into a new workspace).
final class IncognitoWorkspaceLedger {
    private let url: URL
    private var written: Set<String>?
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
    }

    /// The ids the last run left (read off the main thread).
    func load() async -> [String] {
        let url = url
        return await Task.detached(priority: .userInitiated) {
            // concurrency-allow: runs in a detached task, off the main actor
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [String]() }
            return document.workspaces
        }.value
    }

    /// Records `ids` when they changed (written off the main thread).
    func record(_ ids: Set<String>) {
        guard ids != written else { return }
        written = ids
        let url = url, logger = logger
        let data = try? JSONEncoder().encode(Document(workspaces: ids.sorted()))
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                if let data, !ids.isEmpty {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                logger.error("incognito ledger write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
