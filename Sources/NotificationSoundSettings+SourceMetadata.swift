import Foundation

extension NotificationSoundSettings {
    static func sourceSignature(for sourceURL: URL) -> String {
        let normalizedPath = sourceURL.standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalizedPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func currentMetadata(
        for sourceURL: URL,
        fileManager: FileManager
    ) -> NotificationSoundSourceMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let sourceSize = attributes[.size] as? NSNumber else {
            return nil
        }
        let sourceDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return NotificationSoundSourceMetadata(
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceSize: sourceSize.uint64Value,
            sourceModificationTime: sourceDate.timeIntervalSinceReferenceDate,
            sourceFileIdentifier: fileIdentifier
        )
    }

    static func loadMetadata(for stagedURL: URL) -> NotificationSoundSourceMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: stagedURL)) else {
            return nil
        }
        return try? JSONDecoder().decode(NotificationSoundSourceMetadata.self, from: data)
    }

    static func saveMetadata(
        _ metadata: NotificationSoundSourceMetadata,
        for stagedURL: URL
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: stagedURL), options: .atomic)
    }

    private static func metadataURL(for stagedURL: URL) -> URL {
        stagedURL.appendingPathExtension("source-metadata")
    }
}
