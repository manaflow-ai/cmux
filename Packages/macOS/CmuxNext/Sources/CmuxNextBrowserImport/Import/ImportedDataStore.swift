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

    /// Saves `batch`, replacing its source's earlier one. The source's Clear History
    /// fences stay: pages last visited in them are left out, so a re-import does not
    /// bring cleared history back. Returns the batch as saved, and the earlier batch
    /// when it was in another profile (a re-import moved the source): its file is
    /// gone, and the caller takes its bookmarks and pages out of that profile.
    @discardableResult
    public func save(_ batch: ImportBatch) throws -> (saved: ImportBatch, displaced: ImportBatch?) {
        var batch = batch
        let earlier = sources().first { $0.sourceKey == batch.source.sourceKey }?.clearedRanges ?? []
        let cleared = Self.coalesced(earlier + (batch.source.clearedRanges ?? []))
        batch.source.clearedRanges = cleared.isEmpty ? nil : cleared
        batch.history = batch.history.filter { page in !cleared.contains { $0.contains(page.lastVisit) } }
        let file = batchFile(batch.source)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(batch).write(to: file, options: .atomic)
        var displaced: ImportBatch?
        for old in sources() where old.sourceKey == batch.source.sourceKey && old.targetProfileID != batch.source.targetProfileID {
            displaced = (try? Data(contentsOf: batchFile(old))).flatMap { try? decoder.decode(ImportBatch.self, from: $0) }
            try? FileManager.default.removeItem(at: batchFile(old))
        }
        var records = sources().filter { $0.sourceKey != batch.source.sourceKey }
        records.append(batch.source)
        try encoder.encode(records).write(to: sourcesFile, options: .atomic)
        return (batch, displaced)
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

    /// Keep in Sync: replaces one source's saved pages with a fresh read
    /// (less any a Clear History removed) and returns its record and the pages
    /// that are new or changed since the last read; nil when the source is
    /// unknown, no longer synced or its data was removed (nothing is written then).
    public func replaceHistory(_ sourceKey: String, with read: [ImportedHistoryEntry]) throws
        -> (record: ImportSourceRecord, changed: [ImportedHistoryEntry])? {
        guard let record = sources().first(where: { $0.sourceKey == sourceKey && $0.syncedHistoryFile != nil }),
              let data = try? Data(contentsOf: batchFile(record)), var batch = try? decoder.decode(ImportBatch.self, from: data) else { return nil }
        let cleared = record.clearedRanges ?? []
        let pages = read.filter { page in !cleared.contains { $0.contains(page.lastVisit) } }
        let old = Set(batch.history)
        let changed = pages.filter { !old.contains($0) }
        guard !changed.isEmpty || pages.count != batch.history.count else { return (record, []) }
        batch.history = pages
        batch.importedAt = Date()
        try encoder.encode(batch).write(to: batchFile(record), options: .atomic)
        return (record, changed)
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

    /// Clear History: drops the saved imported pages of `profile` (nil: every
    /// profile) last visited at or after `since` (nil: all), so a cleared page
    /// does not come back at the next launch, and fences that time off from
    /// later Keep in Sync reads.
    public func forgetHistory(profile: String?, since: Date?) throws {
        let range = DateInterval(start: since ?? .distantPast, end: Date())
        var records = sources()
        for index in records.indices where profile == nil || records[index].targetProfileID == profile {
            records[index].clearedRanges = Self.coalesced((records[index].clearedRanges ?? []) + [range])
            guard let data = try? Data(contentsOf: batchFile(records[index])),
                  var batch = try? decoder.decode(ImportBatch.self, from: data) else { continue }
            let kept = batch.history.filter { !range.contains($0.lastVisit) }
            guard kept.count != batch.history.count else { continue }
            batch.history = kept
            try encoder.encode(batch).write(to: batchFile(records[index]), options: .atomic)
        }
        try encoder.encode(records).write(to: sourcesFile, options: .atomic)
    }

    /// `ranges` sorted, with overlapping and touching ones merged: each Clear History
    /// ends now, so repeated clears collapse into a few fences instead of growing the record.
    public static func coalesced(_ ranges: [DateInterval]) -> [DateInterval] {
        ranges.sorted { $0.start < $1.start }.reduce(into: []) { merged, range in
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
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
