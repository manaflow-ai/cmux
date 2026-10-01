public import Foundation

/// An ``OutboxStoring`` that keeps one JSON file per conversation key in a
/// directory the app chooses.
///
/// ```swift
/// let outbox = FileOutboxStore(directory: appSupport.appending(path: "Outbox"))
/// ```
public actor FileOutboxStore: OutboxStoring {
    private let directory: URL
    private let fileManager: FileManager

    /// Creates a store.
    /// - Parameters:
    ///   - directory: Where to keep the files; created on first save.
    ///   - fileManager: The file manager to use.
    public init(directory: URL, fileManager: FileManager = FileManager()) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    /// The stored messages for `key`, or none.
    /// - Parameter key: The conversation key.
    /// - Returns: The stored messages.
    public func load(key: String) async -> [OutgoingMessage] {
        guard let data = try? Data(contentsOf: url(key)) else { return [] }
        return (try? JSONDecoder().decode([OutgoingMessage].self, from: data)) ?? []
    }

    /// Replaces the stored messages for `key`.
    /// - Parameters:
    ///   - messages: The messages; empty removes the file.
    ///   - key: The conversation key.
    public func save(_ messages: [OutgoingMessage], key: String) async {
        let target = url(key)
        if messages.isEmpty {
            try? fileManager.removeItem(at: target)
            return
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: target, options: .atomic)
        }
    }
}
