import Foundation

/// Atomic, credential-free, bounded persistence for queued push envelopes.
actor PhonePushQueueStore {
    private let fileURL: URL
    private let capacity: Int
    private let fileManager: FileManager

    init(
        fileURL: URL,
        capacity: Int = PhonePushSerialDeliveryQueue.defaultCapacity,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        self.fileManager = fileManager
    }

    static func live() -> Self {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return Self(fileURL: root
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("phone-push-queue-v1.json"))
    }

    func load(nowEpochSeconds: Int) throws -> [PhonePushRequestEnvelope] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(
            [PhonePushRequestEnvelope].self,
            from: data
        )
        let current = decoded.filter { !$0.isExpired(at: nowEpochSeconds) }
        return Array(
            PhonePushSerialDeliveryQueue.normalized(current).suffix(capacity)
        )
    }

    func save(_ envelopes: [PhonePushRequestEnvelope]) throws {
        let bounded = Array(
            PhonePushSerialDeliveryQueue.normalized(envelopes).suffix(capacity)
        )
        guard !bounded.isEmpty else {
            try clear()
            return
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(bounded)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
