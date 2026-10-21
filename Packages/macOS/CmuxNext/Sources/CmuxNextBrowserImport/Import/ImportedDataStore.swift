public import Foundation

/// Imported data on disk: one JSON file per source profile under
/// `<directory>/<target profile>/`, plus `sources.json`, the mapping from each
/// source profile to its proposed and current cmux browser profile. A repeat
/// import of the same source replaces its file, so nothing is duplicated.
/// An actor: every read and write happens off the main thread.
public actor ImportedDataStore {
    public let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public init(directory: URL) {
        self.directory = directory
    }

    private var sourcesFile: URL { directory.appending(path: "sources.json") }

    private func batchFile(_ record: ImportSourceRecord) -> URL {
        let safe = record.sourceKey.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appending(path: record.targetProfileID, directoryHint: .isDirectory)
            .appending(path: String(safe) + ".json")
    }

    public func save(_ batch: ImportBatch) throws {
        let file = batchFile(batch.source)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(batch).write(to: file, options: .atomic)
        // A re-import into another profile moves the source: its old copy goes, so nothing shows twice.
        for old in sources() where old.sourceKey == batch.source.sourceKey && old.targetProfileID != batch.source.targetProfileID {
            try? FileManager.default.removeItem(at: batchFile(old))
        }
        var records = sources().filter { $0.sourceKey != batch.source.sourceKey }
        records.append(batch.source)
        try encoder.encode(records).write(to: sourcesFile, options: .atomic)
    }

    /// Every source mapping saved so far.
    public func sources() -> [ImportSourceRecord] {
        guard let data = try? Data(contentsOf: sourcesFile) else { return [] }
        return (try? decoder.decode([ImportSourceRecord].self, from: data)) ?? []
    }

    /// The proposed profile id already given to a source, so re-imports keep it.
    public func proposedProfileID(for sourceKey: String) -> String? {
        sources().first { $0.sourceKey == sourceKey }?.proposedProfileID
    }

    /// Sources an import put into another profile than their own (source key to that profile).
    public func movedSources() -> [String: String] {
        let moved = sources().filter { $0.targetProfileID != $0.proposedProfileID }
        return Dictionary(moved.map { ($0.sourceKey, $0.targetProfileID) }, uniquingKeysWith: { first, _ in first })
    }

    /// Sources whose data still sits in the default profile (imports made
    /// before browser profiles existed).
    public func sourcesInDefaultProfile() -> [ImportSourceRecord] {
        sources().filter { $0.targetProfileID == "default" }
    }

    /// Moves one source's saved batch into `profile` and records the new
    /// target. An unknown source is a no-op.
    public func retarget(_ sourceKey: String, to profile: String) throws {
        var records = sources()
        guard let index = records.firstIndex(where: { $0.sourceKey == sourceKey }) else { return }
        let old = records[index]
        guard old.targetProfileID != profile else { return }
        var moved = old
        moved.targetProfileID = profile
        let from = batchFile(old), to = batchFile(moved)
        if let data = try? Data(contentsOf: from), var batch = try? decoder.decode(ImportBatch.self, from: data) {
            batch.source = moved
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(batch).write(to: to, options: .atomic)
            try? FileManager.default.removeItem(at: from)
        }
        records[index] = moved
        try encoder.encode(records).write(to: sourcesFile, options: .atomic)
    }

    /// Keep in Sync's sources: those whose history is read again on change.
    public func syncedSources() -> [ImportSourceRecord] {
        sources().filter { $0.syncedHistoryFile != nil }
    }

    /// Keep in Sync: replaces one source's saved pages with a fresh read and
    /// returns its record; nil when the source is unknown, no longer synced
    /// or its data was removed (nothing is written then).
    public func replaceHistory(_ sourceKey: String, with pages: [ImportedHistoryEntry]) throws -> ImportSourceRecord? {
        guard let record = sources().first(where: { $0.sourceKey == sourceKey && $0.syncedHistoryFile != nil }),
              let data = try? Data(contentsOf: batchFile(record)), var batch = try? decoder.decode(ImportBatch.self, from: data) else { return nil }
        batch.history = pages
        batch.importedAt = Date()
        try encoder.encode(batch).write(to: batchFile(record), options: .atomic)
        return record
    }

    /// Turns Keep in Sync off for every source in `profile`, or for one source.
    public func stopSync(profile: String? = nil, sourceKey: String? = nil) throws {
        var records = sources()
        for index in records.indices where (profile == nil || records[index].targetProfileID == profile)
            && (sourceKey == nil || records[index].sourceKey == sourceKey) {
            records[index].syncedHistoryFile = nil
        }
        try encoder.encode(records).write(to: sourcesFile, options: .atomic)
    }

    /// Remove Imported Data: deletes every batch saved into `profile` and
    /// stops its sync; returns them so the caller takes their pages and
    /// bookmarks out of the live browser. The mapping stays, so importing
    /// again reuses the same profile.
    public func removeImported(profile: String) throws -> [ImportBatch] {
        let removed = batches(profile: profile)
        try? FileManager.default.removeItem(at: directory.appending(path: profile, directoryHint: .isDirectory))
        try stopSync(profile: profile)
        return removed
    }

    /// Clear History: drops the saved imported pages of `profile` visited at
    /// or after `since` (nil: all, which also stops its Keep in Sync), so a
    /// cleared page does not come back at the next launch.
    public func forgetHistory(profile: String, since: Date?) throws {
        if since == nil { try stopSync(profile: profile) }
        for var batch in batches(profile: profile) {
            let kept = batch.history.filter { page in since.map { page.lastVisit < $0 } ?? false }
            guard kept.count != batch.history.count else { continue }
            batch.history = kept
            try encoder.encode(batch).write(to: batchFile(batch.source), options: .atomic)
        }
    }

    /// Every batch imported into `profile`.
    public func batches(profile: String) -> [ImportBatch] {
        let folder = directory.appending(path: profile, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(ImportBatch.self, from: data)
        }
    }
}
