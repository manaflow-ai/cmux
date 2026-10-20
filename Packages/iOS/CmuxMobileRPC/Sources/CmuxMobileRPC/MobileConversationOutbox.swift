import Foundation

/// Persists intent before a command crosses the network. Entries are reconciled
/// by ID after reconnect; loading this store never dispatches provider work.
actor MobileConversationOutbox {
    struct Entry: Codable, Sendable, Equatable {
        let commandID: String
        let sessionID: String
        let command: Data
        let createdAt: Date
        var receipt: Data?
        var settled: Bool
    }

    private let fileURL: URL
    private var entries: [String: Entry]
    private let maximumEntries = 512
    private let maximumCommandBytes = 1_048_576

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) <= 16_777_216 else {
                throw OutboxError.capacityExceeded
            }
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))
            guard entries.count <= maximumEntries,
                  entries.allSatisfy({ key, value in
                      key == value.commandID && !key.isEmpty && !value.sessionID.isEmpty
                          && value.command.count <= maximumCommandBytes
                  }) else { throw OutboxError.invalidStore }
        } else {
            entries = [:]
        }
    }

    func stage(commandID: String, sessionID: String, command: Data) throws {
        guard command.count <= maximumCommandBytes else { throw OutboxError.capacityExceeded }
        if let previous = entries[commandID] {
            guard previous.sessionID == sessionID, previous.command == command else {
                throw OutboxError.commandIDCollision
            }
            return
        }
        var next = entries
        if next.count >= maximumEntries {
            let completed = next.values.filter(\.settled).sorted { $0.createdAt < $1.createdAt }
            for entry in completed.prefix(maximumEntries / 2) {
                next.removeValue(forKey: entry.commandID)
            }
        }
        // Never make room by forgetting unresolved execution.
        guard next.count < maximumEntries else { throw OutboxError.capacityExceeded }
        next[commandID] = Entry(
            commandID: commandID,
            sessionID: sessionID,
            command: command,
            createdAt: Date(),
            receipt: nil,
            settled: false
        )
        try persist(next)
        entries = next
    }

    func record(commandID: String, receipt: Data, settled: Bool) throws {
        guard var entry = entries[commandID] else { return }
        // A timeout from a retiring connection can arrive after a replacement
        // connection has reconciled the durable outcome. Final receipts never regress.
        guard !entry.settled else { return }
        entry.receipt = receipt
        entry.settled = settled
        var next = entries
        next[commandID] = entry
        try persist(next)
        entries = next
    }

    func pending(sessionID: String) -> [Entry] {
        entries.values
            .filter { $0.sessionID == sessionID && !$0.settled }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func persist(_ next: [String: Entry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 16_777_216 else { throw OutboxError.capacityExceeded }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private enum OutboxError: Error {
        case capacityExceeded
        case invalidStore
        case commandIDCollision
    }
}
