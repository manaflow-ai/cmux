import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// Zoom per site (Chrome's per-host zoom): one level per host and browser
/// profile. The browser chrome applies a host's level when a page commits
/// on it and stores it when the user zooms (`SiteZoomFollower`). Levels
/// persist as one JSON file per profile; an incognito profile, or a store
/// without a directory, keeps them in memory.
@MainActor
public final class SiteZoomLevels {
    private let directory: URL?
    private let offTheRecord: OffTheRecordProfiles
    /// Where the files are read and written in order; nil: on ``SiteZoomFile``'s actor.
    private let files: WorkSequence?
    private var levels: [BrowserProfileID: [String: Double]] = [:]
    /// Followers; one that answers false is gone and is dropped.
    private var observers: [UUID: (BrowserProfileID, String) -> Bool] = [:]

    /// Levels in files under `directory` (nil: in memory), an incognito profile's in memory.
    ///
    /// - Parameters:
    ///   - directory: One JSON file per profile; ``BrowserSharedStores/application(files:)`` passes
    ///     `<Application Support>/<bundle id>/SiteZoom/` (tagged DEV builds have their own bundle id).
    ///   - offTheRecord: The App's incognito profiles (``BrowserSharedStores``).
    ///   - files: A files-lane sequence the reads and writes run in, in order (the App's); nil runs them on an actor.
    public init(directory: URL?, offTheRecord: OffTheRecordProfiles, files: WorkSequence? = nil) {
        self.directory = directory
        self.offTheRecord = offTheRecord
        self.files = files
    }

    /// The stored level of `host`, nil for the default (100%).
    public func level(host: String, profile: BrowserProfileID) -> Double? {
        loaded(profile)[host.lowercased()]
    }

    /// Stores `level` for `host` (100% removes it) and tells every follower.
    public func set(_ level: Double, host: String, profile: BrowserProfileID) {
        let host = host.lowercased()
        var table = loaded(profile)
        let value: Double? = abs(level - 1) < 0.001 ? nil : level
        guard table[host] != value else { return }
        table[host] = value
        levels[profile] = table
        save(table, profile: profile)
        notify(profile, host)
    }

    /// Calls `change` after a host's level changes, until it returns false.
    public func observe(_ change: @escaping (BrowserProfileID, String) -> Bool) {
        observers[UUID()] = change
    }

    /// Reads `profile`'s file once (off the main actor). Levels set before
    /// it arrives win over the file; followers re-apply what it brings.
    public func load(_ profile: BrowserProfileID) async {
        await beginLoad(profile)?.value
    }

    private var requested: Set<BrowserProfileID> = []
    private var pending: [BrowserProfileID: Task<Void, Never>] = [:]

    /// The read of `profile`'s file, started now when it has not been; nil once it landed or with no file.
    @discardableResult
    private func beginLoad(_ profile: BrowserProfileID) -> Task<Void, Never>? {
        guard !requested.contains(profile) else { return pending[profile] }
        requested.insert(profile)
        guard let file = file(for: profile) else { return nil }
        // task-owner: the profile's one read (`pending`); load() awaits it.
        // main-hop-allow: the read runs on the files lane (or SiteZoomFile's actor); the resume merges it into this store's few-entry table and tells its followers
        let task = Task { [weak self, files] in
            let stored: [String: Double]
            if let files {
                stored = (try? await files.run(.userVisible) { SiteZoomFile.readNow(file) }) ?? [:]
            } else {
                stored = await SiteZoomFile.read(file)
            }
            self?.merge(stored, into: profile)
        }
        pending[profile] = task
        return task
    }

    /// `profile`'s file arrived: levels set before it win over the file, and followers re-apply what it brings.
    private func merge(_ stored: [String: Double], into profile: BrowserProfileID) {
        var table = stored
        table.merge(levels[profile] ?? [:]) { _, current in current }
        levels[profile] = table
        pending[profile] = nil
        for host in stored.keys { notify(profile, host) }
    }

    private func loaded(_ profile: BrowserProfileID) -> [String: Double] {
        beginLoad(profile)
        return levels[profile] ?? [:]
    }

    private func notify(_ profile: BrowserProfileID, _ host: String) {
        for (token, observer) in observers where !observer(profile, host) { observers[token] = nil }
    }

    /// Writes in order: each write waits for the one before it.
    private var lastWrite: Task<Void, Never>?

    private func save(_ table: [String: Double], profile: BrowserProfileID) {
        guard let file = file(for: profile) else { return }
        if let files {  // in order behind the reads and writes before it
            files.post(.bestEffort, shutdown: .blockShutdown) { SiteZoomFile.writeNow(table, to: file) }
            return
        }
        let previous = lastWrite
        // task-owner: the write chain (`lastWrite`). Off main: nothing of it runs on the main thread.
        lastWrite = Task { @concurrent in
            await previous?.value
            await SiteZoomFile.write(table, to: file)
        }
    }

    private func file(for profile: BrowserProfileID) -> URL? {
        guard let directory, !offTheRecord.isOffTheRecord(profile) else { return nil }
        return directory.appending(path: profile.rawValue.uuidString + ".json")
    }

    nonisolated static func defaultDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return support.appending(path: bundle).appending(path: "SiteZoom")
    }
}

/// The per-profile zoom files, read and written off the main actor.
private actor SiteZoomFile {
    static let shared = SiteZoomFile()

    static func read(_ file: URL) async -> [String: Double] { await shared.read(file) }
    static func write(_ table: [String: Double], to file: URL) async { await shared.write(table, to: file) }

    private func read(_ file: URL) -> [String: Double] { Self.readNow(file) }

    private func write(_ table: [String: Double], to file: URL) { Self.writeNow(table, to: file) }

    /// The levels in `file`, empty when it is missing or unreadable. Blocking: this actor or a files lane.
    nonisolated static func readNow(_ file: URL) -> [String: Double] {
        // concurrency-allow: runs on this actor's executor or a files lane, never the main actor.
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().blockingDecode([String: Double].self, from: data)) ?? [:]
    }

    /// Writes `table` to `file` atomically, making its folder. Blocking: this actor or a files lane.
    nonisolated static func writeNow(_ table: [String: Double], to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(table) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
