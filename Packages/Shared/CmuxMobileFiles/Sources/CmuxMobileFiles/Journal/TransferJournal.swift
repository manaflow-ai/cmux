import Foundation

/// The phone's transfer records, persisted as one JSON file (complete file
/// protection) so paused transfers survive a relaunch. Client view state:
/// nothing here is shared or synced.
public actor TransferJournal {
    public let fileURL: URL?
    private var records: [String: TransferRecord] = [:]
    /// False while the file exists but could not be read (the device is
    /// locked during a background launch): nothing is written until a later
    /// read succeeds, so an empty journal never overwrites a real one.
    private var loaded: Bool

    /// `fileURL` nil keeps records in memory (tests, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        loaded = fileURL == nil
        if let fileURL { loaded = Self.read(fileURL, into: &records) }
    }

    /// Reads the file; true when it was read or does not exist. A file that
    /// reads but does not decode is moved aside as corrupt.
    private static func read(_ url: URL, into records: inout [String: TransferRecord]) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let decoded = try? JSONDecoder().decode([TransferRecord].self, from: data) else {
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            return true
        }
        for var record in decoded where records[record.id] == nil {
            // A transfer that was running when the app died is paused now.
            if record.status == .running { record.status = .paused }
            records[record.id] = record
        }
        return true
    }

    public func all() -> [TransferRecord] {
        records.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(_ id: String) -> TransferRecord? {
        records[id]
    }

    public func put(_ record: TransferRecord) {
        records[record.id] = record
        persist()
    }

    @discardableResult
    public func update(_ id: String, _ change: (inout TransferRecord) -> Void) -> TransferRecord? {
        guard var record = records[id] else { return nil }
        change(&record)
        records[id] = record
        persist()
        return record
    }

    public func remove(_ id: String) {
        records[id] = nil
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        if !loaded { loaded = Self.read(fileURL, into: &records) }
        guard loaded else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(records.values)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: fileURL, options: .atomic)
        #endif
    }
}
