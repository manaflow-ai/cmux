import Darwin
import Foundation

/// Bounds managed custom-sound artifacts so repeated one-off selections do not
/// grow the user's sound directory without limit.
nonisolated struct NotificationSoundStagingArtifactCleaner: Sendable {
    private let maximumArtifacts = 64
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    func prune(in directory: URL, preserving preservedURLs: [URL]) {
        let fileManager = FileManager.default
        // `contentsOfDirectory` is intentionally shallow. The newer
        // `.skipsSubdirectoryEnumeration` option is unavailable to the
        // macOS 14 deployment target on older Xcode SDKs.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let preserved = Set(preservedURLs.map(\.standardizedFileURL))
        let cutoff = Date().addingTimeInterval(-maximumAge)
        let modificationDate: (URL) -> Date = { url in
            (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                ?? .distantPast
        }
        // Only the newest bounded set of unleased recent artifacts is retained
        // in memory; old artifacts and over-cap recent artifacts are removed
        // as they are encountered.
        var recentArtifacts: [(url: URL, modifiedAt: Date)] = []
        for entry in entries {
            guard isManagedArtifact(entry),
                  !preserved.contains(entry.standardizedFileURL) else {
                continue
            }
            let modifiedAt = modificationDate(entry)
            if modifiedAt < cutoff {
                removeArtifact(entry, fileManager: fileManager)
                continue
            }
            recentArtifacts.append((entry, modifiedAt))
            guard recentArtifacts.count > maximumArtifacts else { continue }
            guard let oldestIndex = recentArtifacts.indices.min(by: {
                recentArtifacts[$0].modifiedAt < recentArtifacts[$1].modifiedAt
            }) else { continue }
            let oldest = recentArtifacts.remove(at: oldestIndex)
            removeArtifact(oldest.url, fileManager: fileManager)
        }
    }

    private func removeArtifact(_ url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(
            at: url.appendingPathExtension("source-metadata")
        )
    }

    private func isManagedArtifact(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory != true else {
            return false
        }
        let prefix = NotificationSoundSettings.customSoundBaseName + "-"
        guard url.lastPathComponent.hasPrefix(prefix),
              !url.lastPathComponent.hasSuffix(".source-metadata"),
              NotificationSoundSettings.supportedCustomSoundExtensions.contains(
                  url.pathExtension.lowercased()
              ) else {
            return false
        }
        guard let metadata = NotificationSoundSettings.loadMetadata(for: url),
              (metadata.owner == NotificationSoundSourceMetadata.ownerMarker
                || isValidatedLegacyMetadata(metadata)),
              !metadata.sourcePath.isEmpty else {
            return false
        }
        let sourceURL = URL(fileURLWithPath: metadata.sourcePath, isDirectory: false)
        guard NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: url.pathExtension
        ) == url.lastPathComponent else {
            return false
        }
        let basename = url.deletingPathExtension().lastPathComponent
        let signature = basename.dropFirst(prefix.count)
        guard signature.utf8.count == 16 else { return false }
        return signature.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 97 && byte <= 102)
        }
    }

    private func isValidatedLegacyMetadata(
        _ metadata: NotificationSoundSourceMetadata
    ) -> Bool {
        guard metadata.owner == nil else { return false }
        let sourceURL = URL(fileURLWithPath: metadata.sourcePath, isDirectory: false)
        if let current = NotificationSoundSettings.currentMetadata(
            for: sourceURL,
            fileManager: FileManager.default
        ) {
            return current.sourcePath == metadata.sourcePath
                && current.sourceSize == metadata.sourceSize
                && current.sourceModificationTime == metadata.sourceModificationTime
                && current.sourceFileIdentifier == metadata.sourceFileIdentifier
        }
        // A missing source is a normal orphan state after a user moves or
        // deletes the original file. The legacy sidecar itself is the cmux
        // ownership marker; retain only structurally valid absolute paths and
        // finite metadata so the orphan can be reclaimed by age/count policy.
        return sourceURL.path.hasPrefix("/")
            && metadata.sourceModificationTime.isFinite
    }
}

extension NotificationSoundSettings {
    private static let sourceSignatureHexDigits = Array("0123456789abcdef".utf8)
    private static let maximumSourceMetadataBytes = 16 * 1024

    static func sourceSignature(for sourceURL: URL) -> String {
        let normalizedPath = sourceURL.standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalizedPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        // Keep this concurrent staging hot path independent of C varargs.
        // Foundation's format bridge has produced unbounded allocations and
        // crashes for integer values on supported macOS toolchains.
        var encoded = [UInt8](repeating: sourceSignatureHexDigits[0], count: 16)
        for index in stride(from: encoded.count - 1, through: 0, by: -1) {
            encoded[index] = sourceSignatureHexDigits[Int(hash & 0x0f)]
            hash >>= 4
        }
        return String(decoding: encoded, as: UTF8.self)
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
            sourceFileIdentifier: fileIdentifier,
            owner: NotificationSoundSourceMetadata.ownerMarker
        )
    }

    static func loadMetadata(for stagedURL: URL) -> NotificationSoundSourceMetadata? {
        guard let data = boundedMetadataData(
            at: metadataURL(for: stagedURL),
            maximumBytes: maximumSourceMetadataBytes
        ) else { return nil }
        return try? JSONDecoder().decode(NotificationSoundSourceMetadata.self, from: data)
    }

    private static func boundedMetadataData(
        at url: URL,
        maximumBytes: Int
    ) -> Data? {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else {
            return nil
        }

        let expectedBytes = Int(info.st_size)
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: min(4096, maximumBytes))
        while data.count < expectedBytes {
            let requested = min(buffer.count, expectedBytes - data.count)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, requested)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if readCount == 0 { return nil }
            data.append(contentsOf: buffer.prefix(Int(readCount)))
        }
        return data.count == expectedBytes ? data : nil
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
