public import Foundation

/// The record of the temporary `.cmuxdownload` files cmux itself writes
/// (`BrowserDownloadPlacement.temporaryURL`), so a run that ends while it
/// downloads (a crash, a kill, a power-off) leaves nothing behind for good:
/// a placement adds its temporary file when it starts and removes it when it
/// lands or is discarded, and the next launch (`cleanUpLeftovers`) deletes
/// the leftovers of earlier runs.
///
/// The cleanup deletes only paths in the record, never by pattern: a
/// recorded path is deleted only when it is absolute, its name still ends in
/// `.cmuxdownload`, and it is a regular file itself (`lstat`; a symlink is
/// never followed or deleted). Chromium's `<temporary>.crdownload` of a
/// recorded path is checked the same way. Downloads this run started are
/// never touched. The record is a small JSON file read and written off the
/// main actor, in order.
public final class BrowserDownloadTempFiles {
    /// `<Application Support>/<bundle id>/download-temp-files.json`.
    public static let shared = BrowserDownloadTempFiles(recordURL: defaultRecordURL())

    private let store: Store
    /// The latest record change; the next one waits for it, so changes land
    /// in order.
    private var last: Task<Void, Never>?

    public init(recordURL: URL) {
        store = Store(recordURL: recordURL)
    }

    /// A placement started: `url` is its temporary file.
    func add(_ url: URL) { enqueue(.add(Self.path(url))) }

    /// A placement landed or was discarded.
    func remove(_ url: URL) { enqueue(.remove(Self.path(url))) }

    /// At launch: deletes the leftovers of earlier runs (off the main actor).
    public func cleanUpLeftovers() { enqueue(.cleanUp) }

    /// Returns when every change so far has landed (tests).
    func idle() async { await last?.value }

    private func enqueue(_ change: Change) {
        let previous = last, store = store
        last = Task.detached(priority: .utility) {
            await previous?.value
            await store.apply(change)
        }
    }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }

    nonisolated static func defaultRecordURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return support.appending(path: bundle).appending(path: "download-temp-files.json")
    }

    nonisolated enum Change: Sendable {
        case add(String)
        case remove(String)
        case cleanUp
    }

    /// The record file. It is read once, at the first change, so a
    /// download that starts before the launch cleanup keeps the earlier
    /// leftovers in the record.
    private actor Store {
        private let recordURL: URL
        private var paths: Set<String>?
        /// The paths this run added: the cleanup never deletes them.
        private var live: Set<String> = []

        init(recordURL: URL) {
            self.recordURL = recordURL
        }

        func apply(_ change: Change) {
            var current = paths ?? read()
            switch change {
            case .add(let path):
                live.insert(path)
                current.insert(path)
            case .remove(let path):
                live.remove(path)
                current.remove(path)
            case .cleanUp:
                for path in current.subtracting(live) {
                    Self.deleteLeftover(path)
                    current.remove(path)
                }
            }
            if current != paths { write(current) }
            paths = current
        }

        private func read() -> Set<String> {
            // concurrency-allow: runs on this actor's executor, never the main actor.
            guard let data = try? Data(contentsOf: recordURL),
                  let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
            return Set(document.paths)
        }

        private func write(_ paths: Set<String>) {
            let manager = FileManager.default
            if paths.isEmpty {
                try? manager.removeItem(at: recordURL)
                return
            }
            guard let data = try? JSONEncoder().encode(Document(paths: paths.sorted())) else { return }
            try? manager.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: recordURL, options: .atomic)
        }

        /// Deletes `path` and its Chromium partial when each is a regular
        /// `.cmuxdownload` file of cmux's (see the type's rules).
        private static func deleteLeftover(_ path: String) {
            guard path.hasPrefix("/"), path.hasSuffix(".cmuxdownload") else { return }
            for candidate in [path, path + ".crdownload"] where isRegularFile(candidate) {
                unlink(candidate)
            }
        }

        /// `lstat`: true only for a regular file itself, never for a
        /// symlink (to anything), a directory or a missing path.
        private static func isRegularFile(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
    }

    nonisolated private struct Document: Codable, Sendable {
        var paths: [String]
    }
}
