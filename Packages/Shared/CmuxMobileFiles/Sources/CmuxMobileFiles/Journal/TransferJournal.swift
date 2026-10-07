import Foundation

/// The phone's transfer records, persisted as one JSON file (complete file
/// protection) so paused transfers survive a relaunch. Client view state:
/// nothing here is shared or synced.
public actor TransferJournal {
    public let fileURL: URL?
    private var records: [String: TransferRecord]

    /// `fileURL` nil keeps records in memory (tests, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TransferRecord].self, from: data) {
            // A transfer that was running when the app died is paused now.
            records = Dictionary(uniqueKeysWithValues: decoded.map { record in
                var record = record
                if record.status == .running { record.status = .paused }
                return (record.id, record)
            })
        } else {
            records = [:]
        }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(records.values)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: fileURL, options: .atomic)
        #endif
    }
}
