public import Foundation

/// Filesystem-backed staging and finalization for mobile task attachments.
///
/// The store carries no shared runtime state. Upload identity, progress, and
/// completion are represented on disk, so constructing a fresh store for each
/// RPC preserves idempotency across retries and app restarts.
public struct MobileTaskAttachmentStore {
    /// Maximum raw bytes in one uploaded file.
    public static let maximumFileBytes = 32 * 1024 * 1024
    /// Maximum raw bytes in one base64 RPC chunk.
    public static let maximumChunkBytes = 3 * 1024 * 1024
    /// Maximum attachment identities in one task operation.
    public static let maximumAttachmentsPerOperation = 10
    /// Maximum declared raw bytes across one task operation.
    public static let maximumOperationBytes = 64 * 1024 * 1024
    /// Age after which abandoned operation directories are pruned.
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private struct StagingMetadata: Codable {
        let fileName: String
        let totalBytes: Int
    }

    private struct CompletionRecord: Codable {
        let fileName: String
    }

    private let rootURL: URL
    private let now: Date
    private let fileManager: FileManager

    /// Creates a task attachment store.
    ///
    /// - Parameters:
    ///   - rootURL: Root containing per-operation attachment directories.
    ///   - now: Current time used for pruning.
    ///   - fileManager: Filesystem implementation to use.
    public init(
        rootURL: URL,
        now: Date,
        fileManager: FileManager
    ) {
        self.rootURL = rootURL
        self.now = now
        self.fileManager = fileManager
    }

    /// Default cache root under a user's home directory.
    ///
    /// - Parameter homeDirectory: Home directory that owns the cache.
    /// - Returns: `~/.cache/cmux/task-attachments`.
    public static func defaultRootURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("task-attachments", isDirectory: true)
    }

    /// Sanitizes an untrusted file name into a safe basename.
    ///
    /// Separators, NULs, and control characters become underscores; leading
    /// dots are removed so uploads cannot create hidden files.
    ///
    /// - Parameter rawName: Untrusted client-provided file name.
    /// - Returns: A nonempty safe basename.
    public static func sanitizedFileName(_ rawName: String) -> String {
        var characters: [Character] = []
        var previousWasReplacement = false
        for character in rawName {
            let isUnsafe = character == "/" || character == "\\"
                || character.unicodeScalars.contains {
                    $0.value == 0 || CharacterSet.controlCharacters.contains($0)
                }
            if isUnsafe {
                if !previousWasReplacement {
                    characters.append("_")
                    previousWasReplacement = true
                }
            } else {
                characters.append(character)
                previousWasReplacement = false
            }
        }
        var sanitized = String(characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.first == "." {
            sanitized.removeFirst()
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty {
            sanitized = "attachment"
        }
        return String(sanitized.prefix(180))
    }

    /// Appends one chunk and finalizes the file when requested.
    ///
    /// - Parameter request: Validated identities plus an encoded raw chunk.
    /// - Returns: Staged progress and the final path when complete.
    /// - Throws: ``MobileTaskAttachmentStoreError`` for invalid input or I/O.
    public func upload(
        _ request: MobileTaskAttachmentUploadRequest
    ) throws -> MobileTaskAttachmentUploadResult {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            pruneExpiredOperations(excluding: request.operationID)

            let operationURL = operationDirectory(for: request.operationID)
            let stagingURL = operationURL.appendingPathComponent(".staging", isDirectory: true)
            let metadataURL = operationURL.appendingPathComponent(".metadata", isDirectory: true)
            let completedURL = operationURL.appendingPathComponent(".completed", isDirectory: true)
            for directory in [operationURL, stagingURL, metadataURL, completedURL] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: operationURL.path
            )

            if let completed = try completedResult(
                uploadID: request.uploadID,
                operationURL: operationURL,
                completedURL: completedURL
            ) {
                return completed
            }

            let chunk = try decodedChunk(request.dataBase64)
            try validate(request: request, chunkByteCount: chunk.count)

            let uploadName = request.uploadID.uuidString.lowercased()
            let stagedFileURL = stagingURL.appendingPathComponent(uploadName)
            let stagedMetadataURL = metadataURL
                .appendingPathComponent(uploadName)
                .appendingPathExtension("json")
            let sanitizedName = Self.sanitizedFileName(request.fileName)
            let metadata: StagingMetadata
            if fileManager.fileExists(atPath: stagedMetadataURL.path) {
                metadata = try decode(StagingMetadata.self, at: stagedMetadataURL)
                guard metadata.totalBytes == request.totalBytes,
                      metadata.fileName == sanitizedName else {
                    throw invalidParams("Upload metadata changed during staging")
                }
            } else {
                try enforceOperationCaps(
                    operationURL: operationURL,
                    metadataURL: metadataURL,
                    addingTotalBytes: request.totalBytes
                )
                metadata = StagingMetadata(
                    fileName: sanitizedName,
                    totalBytes: request.totalBytes
                )
                try encode(metadata, to: stagedMetadataURL)
            }

            if !fileManager.fileExists(atPath: stagedFileURL.path) {
                guard request.offset == 0 else {
                    throw invalidParams("Attachment chunks must use contiguous offsets")
                }
                guard fileManager.createFile(atPath: stagedFileURL.path, contents: nil) else {
                    throw storageFailure("Could not create attachment staging file")
                }
            }
            let currentBytes = try fileSize(at: stagedFileURL)
            guard currentBytes == request.offset else {
                throw invalidParams("Attachment chunks must use contiguous offsets")
            }
            guard currentBytes + chunk.count <= metadata.totalBytes else {
                throw invalidParams("Attachment chunk exceeds total_bytes")
            }
            if !chunk.isEmpty {
                let handle = try FileHandle(forWritingTo: stagedFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: chunk)
            }
            let receivedBytes = currentBytes + chunk.count
            guard request.isLast else {
                return MobileTaskAttachmentUploadResult(
                    receivedBytes: receivedBytes,
                    path: nil
                )
            }
            guard receivedBytes == metadata.totalBytes else {
                throw invalidParams("Final attachment byte count does not match total_bytes")
            }

            let finalFileName = deduplicatedFileName(
                metadata.fileName,
                in: operationURL
            )
            let finalURL = operationURL.appendingPathComponent(finalFileName)
            try fileManager.moveItem(at: stagedFileURL, to: finalURL)
            let record = CompletionRecord(fileName: finalFileName)
            let recordURL = completedURL
                .appendingPathComponent(uploadName)
                .appendingPathExtension("json")
            try encode(record, to: recordURL)
            try? fileManager.removeItem(at: stagedMetadataURL)
            return MobileTaskAttachmentUploadResult(
                receivedBytes: receivedBytes,
                path: finalURL.path
            )
        } catch let error as MobileTaskAttachmentStoreError {
            throw error
        } catch {
            throw storageFailure("Could not store task attachment")
        }
    }

    private func operationDirectory(for operationID: UUID) -> URL {
        rootURL.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func completedResult(
        uploadID: UUID,
        operationURL: URL,
        completedURL: URL
    ) throws -> MobileTaskAttachmentUploadResult? {
        let recordURL = completedURL
            .appendingPathComponent(uploadID.uuidString.lowercased())
            .appendingPathExtension("json")
        guard fileManager.fileExists(atPath: recordURL.path) else { return nil }
        let record = try decode(CompletionRecord.self, at: recordURL)
        let finalURL = operationURL.appendingPathComponent(record.fileName)
        guard fileManager.fileExists(atPath: finalURL.path) else {
            try? fileManager.removeItem(at: recordURL)
            return nil
        }
        return MobileTaskAttachmentUploadResult(
            receivedBytes: try fileSize(at: finalURL),
            path: finalURL.path
        )
    }

    private func decodedChunk(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw invalidParams("data_b64 is not valid base64")
        }
        guard data.count <= Self.maximumChunkBytes else {
            throw invalidParams("Attachment chunk exceeds 3 MiB")
        }
        return data
    }

    private func validate(
        request: MobileTaskAttachmentUploadRequest,
        chunkByteCount: Int
    ) throws {
        guard request.totalBytes >= 0,
              request.totalBytes <= Self.maximumFileBytes else {
            throw invalidParams("total_bytes must be between 0 and 32 MiB")
        }
        guard request.offset >= 0,
              request.offset <= request.totalBytes,
              request.offset + chunkByteCount <= request.totalBytes else {
            throw invalidParams("Attachment offset is outside total_bytes")
        }
    }

    private func enforceOperationCaps(
        operationURL: URL,
        metadataURL: URL,
        addingTotalBytes: Int
    ) throws {
        let visibleFiles = try fileManager.contentsOfDirectory(
            at: operationURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let metadataFiles = try fileManager.contentsOfDirectory(
            at: metadataURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard visibleFiles.count + metadataFiles.count
                < Self.maximumAttachmentsPerOperation else {
            throw invalidParams("An operation can contain at most 10 attachments")
        }
        let completedBytes = try visibleFiles.reduce(0) { total, url in
            total + (try fileSize(at: url))
        }
        let stagedBytes = try metadataFiles.reduce(0) { total, url in
            total + (try decode(StagingMetadata.self, at: url).totalBytes)
        }
        guard completedBytes + stagedBytes + addingTotalBytes
                <= Self.maximumOperationBytes else {
            throw invalidParams("An operation can contain at most 64 MiB of attachments")
        }
    }

    private func deduplicatedFileName(_ fileName: String, in directory: URL) -> String {
        let candidate = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: candidate.path) else { return fileName }

        let source = fileName as NSString
        let ext = source.pathExtension
        let stem = source.deletingPathExtension.isEmpty
            ? "attachment"
            : source.deletingPathExtension
        var suffix = 2
        while true {
            let next = ext.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(ext)"
            if !fileManager.fileExists(
                atPath: directory.appendingPathComponent(next).path
            ) {
                return next
            }
            suffix += 1
        }
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw storageFailure("Could not read attachment byte count")
        }
        return size.intValue
    }

    private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func pruneExpiredOperations(excluding operationID: UUID) {
        let currentName = operationID.uuidString.lowercased()
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent != currentName {
            guard let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ), values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func invalidParams(_ message: String) -> MobileTaskAttachmentStoreError {
        MobileTaskAttachmentStoreError(code: "invalid_params", message: message)
    }

    private func storageFailure(_ message: String) -> MobileTaskAttachmentStoreError {
        MobileTaskAttachmentStoreError(code: "internal_error", message: message)
    }
}
