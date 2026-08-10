public import Foundation

/// Copies picker results into app-owned storage without changing their bytes.
public actor MobileAttachmentStager {
    /// A staging failure suitable for localized presentation by the owning UI package.
    public enum StagingError: Error, Sendable, Equatable {
        /// The selected URL did not resolve to a readable regular file.
        case unreadableFile
        /// The selected file exceeds the per-item byte limit.
        case fileTooLarge
    }

    private let rootURL: URL
    private let fileManager: FileManager

    /// Creates a filesystem-backed stager.
    ///
    /// - Parameters:
    ///   - rootURL: App-owned directory that receives uniquely named copies.
    ///   - fileManager: Filesystem implementation used for staging.
    public init(rootURL: URL, fileManager: FileManager) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    /// Creates a stager rooted in the process temporary directory.
    public init() {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mobile-attachments", isDirectory: true)
        self.fileManager = FileManager()
    }

    /// Copies one selected file and returns the exact staged bytes.
    ///
    /// - Parameters:
    ///   - sourceURL: Picker-provided source URL.
    ///   - kind: Image or document presentation.
    ///   - originalFileName: Picker-provided display name.
    /// - Returns: An app-owned exact-byte attachment.
    /// - Throws: ``StagingError`` when the source is unreadable or oversized.
    public func stage(
        sourceURL: URL,
        kind: MobileStagedAttachment.Kind,
        originalFileName: String
    ) throws -> MobileStagedAttachment {
        try Task.checkCancellation()
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw StagingError.unreadableFile
        }
        guard values.isRegularFile == true, let byteCount = values.fileSize else {
            throw StagingError.unreadableFile
        }
        let itemLimit = kind == .image
            ? MobileStagedAttachment.maximumImageBytes
            : MobileStagedAttachment.maximumFileBytes
        guard byteCount <= itemLimit else {
            throw StagingError.fileTooLarge
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let extensionSuffix = sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)"
        let destination = rootURL.appendingPathComponent("\(UUID().uuidString)\(extensionSuffix)")
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            try Task.checkCancellation()
            let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard copiedSize == byteCount else { throw StagingError.unreadableFile }
            return MobileStagedAttachment(
                kind: kind,
                fileName: Self.safeBaseName(originalFileName, fallback: sourceURL.lastPathComponent),
                localFileURL: destination,
                byteCount: byteCount
            )
        } catch let error as StagingError {
            try? fileManager.removeItem(at: destination)
            throw error
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw StagingError.unreadableFile
        }
    }

    private static func safeBaseName(_ requested: String, fallback: String) -> String {
        let requestedBase = (requested as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedBase.isEmpty, requestedBase != ".", requestedBase != ".." {
            return requestedBase
        }
        let fallbackBase = (fallback as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackBase.isEmpty ? "attachment" : fallbackBase
    }
}
