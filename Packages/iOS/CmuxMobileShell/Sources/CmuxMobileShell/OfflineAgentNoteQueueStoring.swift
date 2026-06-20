public import Foundation

/// Persistence interface for mobile offline agent notes.
public protocol OfflineAgentNoteQueueStoring: Sendable {
    func loadNotes() async -> [OfflineAgentNote]
    func saveNotes(_ notes: [OfflineAgentNote]) async
}

/// JSON-backed note queue for small text notes.
public actor FileOfflineAgentNoteQueueStore: OfflineAgentNoteQueueStoring {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public static func defaultStore(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "dev.cmux.ios"
    ) throws -> FileOfflineAgentNoteQueueStore {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileOfflineAgentNoteQueueStore(
            fileURL: directory.appendingPathComponent("offline-agent-notes.json", isDirectory: false)
        )
    }

    public func loadNotes() async -> [OfflineAgentNote] {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode([OfflineAgentNote].self, from: data)
            return decoded.map { note in
                var normalized = note
                if normalized.status == .sending {
                    normalized.status = .pending
                    normalized.lastError = nil
                    normalized.updatedAt = Date()
                }
                return normalized
            }
        } catch {
            return []
        }
    }

    public func saveNotes(_ notes: [OfflineAgentNote]) async {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(notes)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return
        }
    }
}
