public import Foundation

/// Zoom per site (Chrome's per-host zoom): one level per host and browser
/// profile. The browser chrome applies a host's level when a page commits
/// on it and stores it when the user zooms (`SiteZoomFollower`). Levels
/// persist as one JSON file per profile; an incognito profile, or a store
/// without a directory, keeps them in memory.
@MainActor
public final class SiteZoomLevels {
    /// `<Application Support>/<bundle id>/SiteZoom/`; tagged DEV builds have
    /// their own bundle id, so data never mixes.
    public static let shared = SiteZoomLevels(directory: defaultDirectory())

    private let directory: URL?
    private let offTheRecord: OffTheRecordProfiles
    private var levels: [BrowserProfileID: [String: Double]] = [:]
    /// Followers; one that answers false is gone and is dropped.
    private var observers: [UUID: (BrowserProfileID, String) -> Bool] = [:]

    public init(directory: URL?, offTheRecord: OffTheRecordProfiles = .shared) {
        self.directory = directory
        self.offTheRecord = offTheRecord
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
        guard !requested.contains(profile) else { return await pending[profile]?.value ?? () }
        requested.insert(profile)
        guard let file = file(for: profile) else { return }
        let task = Task { [weak self] in
            let stored = await SiteZoomFile.read(file)
            guard let self else { return }
            var table = stored
            table.merge(levels[profile] ?? [:]) { _, current in current }
            levels[profile] = table
            pending[profile] = nil
            for host in stored.keys { notify(profile, host) }
        }
        pending[profile] = task
        await task.value
    }

    private var requested: Set<BrowserProfileID> = []
    private var pending: [BrowserProfileID: Task<Void, Never>] = [:]

    private func loaded(_ profile: BrowserProfileID) -> [String: Double] {
        if !requested.contains(profile) { Task { await load(profile) } }
        return levels[profile] ?? [:]
    }

    private func notify(_ profile: BrowserProfileID, _ host: String) {
        for (token, observer) in observers where !observer(profile, host) { observers[token] = nil }
    }

    /// Writes in order: each write waits for the one before it.
    private var lastWrite: Task<Void, Never>?

    private func save(_ table: [String: Double], profile: BrowserProfileID) {
        guard let file = file(for: profile) else { return }
        let previous = lastWrite
        lastWrite = Task {
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

    private func read(_ file: URL) -> [String: Double] {
        // concurrency-allow: runs on this actor's executor, never the main actor.
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    private func write(_ table: [String: Double], to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(table) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
