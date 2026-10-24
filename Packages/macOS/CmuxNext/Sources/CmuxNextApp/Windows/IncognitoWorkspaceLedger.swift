import CmuxNextWakeups
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
    private let work: BackgroundWork
    /// Writes land in the order they were made, on the files lane.
    private let writes: OrderedWrites
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "incognito")

    init(url: URL, work: BackgroundWork) {
        self.url = url
        self.work = work
        let logger = logger
        writes = OrderedWrites(work: work) { logger.error("incognito ledger write failed: \(String(describing: $0), privacy: .public)") }
    }

    /// `<Application Support>/<bundle id>/incognito-workspaces.json`.
    static func forApplication(bundleIdentifier: String?, work: BackgroundWork) -> IncognitoWorkspaceLedger {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return IncognitoWorkspaceLedger(url: support.appending(path: bundle).appending(path: "incognito-workspaces.json"), work: work)
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
        // Launch closes them before it shows the windows.
        return (try? await work.run(.userVisible, mayBlock: .files) {
            // concurrency-allow: runs on the BackgroundWork files lane, never the main thread or the cooperative pool
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [String]() }
            return document.workspaces
        }) ?? []
    }

    /// Records `ids` when they changed (written on the files lane, in order).
    func record(_ ids: Set<String>) {
        guard ids != written else { return }
        written = ids
        writes.save(ids.isEmpty ? nil : try? JSONEncoder().encode(Document(workspaces: ids.sorted())), to: url)
    }
}
