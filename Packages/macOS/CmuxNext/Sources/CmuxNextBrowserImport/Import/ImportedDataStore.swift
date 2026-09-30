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
