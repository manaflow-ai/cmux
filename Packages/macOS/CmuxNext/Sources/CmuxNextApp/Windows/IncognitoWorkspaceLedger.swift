import CmuxNextCompat
import CmuxNextDesign
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
    /// The ids the last run left, read once on a launch lane (``startLaunchRead(at:on:)``): the launch
    /// window's check and the restore read it, so the main thread never touches the file at launch.
    private let leftovers: LaunchRead<[String]>
    private var written: Set<String>?
    /// The latest write; the next one waits for it, so writes land in order.
    private var lastWrite: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "incognito")

    init(url: URL, leftovers: LaunchRead<[String]>) {
        self.url = url
        self.leftovers = leftovers
    }

    /// The ledger at ``standardURL(bundleIdentifier:)``. `leftovers` is the launch read `main` started
    /// (`AppEnvironment.incognitoLeftovers`); without one (tests that build `AppServices`) it starts on `work`.
    static func forApplication(bundleIdentifier: String?, leftovers: LaunchRead<[String]>?, work: BackgroundWork) -> IncognitoWorkspaceLedger {
        let url = standardURL(bundleIdentifier: bundleIdentifier)
        return IncognitoWorkspaceLedger(url: url, leftovers: leftovers ?? startLaunchRead(at: url, on: work))
    }

    /// `<Application Support>/<bundle id>/incognito-workspaces.json` (a path, no disk call).
    static func standardURL(bundleIdentifier: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return support.appending(path: bundle).appending(path: "incognito-workspaces.json")
    }

    /// Reads the ids the last run left at `url` on `work`'s files lane, at once (`main`, before
    /// `NSApplication.run`). Quit lets it finish: the restore awaits it.
    static func startLaunchRead(at url: URL, on work: BackgroundWork) -> LaunchRead<[String]> {
        LaunchRead(on: work, shutdown: .blockShutdown) { read(url) }
    }

    nonisolated private struct Document: Codable, Sendable {
        var workspaces: [String]
    }

    /// The ids in the file at `url`; none when it is missing or unreadable. Runs on a lane.
    nonisolated private static func read(_ url: URL) -> [String] {
        // concurrency-allow: called only from the launch read, on the files lane
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().blockingDecode(Document.self, from: data) else { return [] }
        return document.workspaces
    }

    /// Whether the last run may have left incognito workspaces: what the launch read found, and true
    /// while it still runs, so a launch window never lists workspaces that may be incognito. No disk call.
    var mayHaveLeftovers: Bool { leftovers.value.map { !$0.isEmpty } ?? true }

    /// The ids the last run left (the launch read's; the caller suspends until it ends).
    func load() async -> [String] {
        await leftovers.finished()
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
