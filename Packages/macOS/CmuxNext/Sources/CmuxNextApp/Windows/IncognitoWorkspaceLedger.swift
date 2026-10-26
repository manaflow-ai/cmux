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
/// off into a new workspace).
final class IncognitoWorkspaceLedger {
    private let url: URL
    private var written: Set<String>?
    /// The latest write; the next one waits for it, so writes land in order.
    private var lastWrite: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "incognito")
    /// The app's blocking-work lanes: the file's read and writes run there.
    private let runner: any MayBlockRunner

    init(url: URL, runner: any MayBlockRunner) {
        self.url = url
        self.runner = runner
    }

    /// `<Application Support>/<bundle id>/incognito-workspaces.json`.
    static func forApplication(bundleIdentifier: String?, runner: any MayBlockRunner) -> IncognitoWorkspaceLedger {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return IncognitoWorkspaceLedger(url: support.appending(path: bundle).appending(path: "incognito-workspaces.json"), runner: runner)
    }

    nonisolated private struct Document: Codable, Sendable {
        var workspaces: [String]
    }

    /// True when the last run left incognito workspaces: the file exists
    /// only while it lists some (an existence check, no read).
    var hasLeftovers: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The ids the last run left (read on the files lane).
    func load() async -> [String] {
        let url = url
        let ids = try? await runner.runFiles(.userBlocking) { () -> [String] in
            guard let data = try? Data(blockingContentsOf: url),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
            return document.workspaces
        }
        return ids ?? []
    }

    /// Records `ids` when they changed (written off the main thread).
    func record(_ ids: Set<String>) {
        guard ids != written else { return }
        written = ids
        let url = url, logger = logger
        let data = try? JSONEncoder().encode(Document(workspaces: ids.sorted()))
        let previous = lastWrite, runner = runner
        // task-owner: lastWrite; each write waits for the one before it, so they land in order.
        lastWrite = Task {
            await previous?.value
            do {
                // The ledger is what closes a crashed run's incognito pages: quit waits for this small write.
                try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) {
                    if let data, !ids.isEmpty {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
            } catch {
                logger.error("incognito ledger write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
