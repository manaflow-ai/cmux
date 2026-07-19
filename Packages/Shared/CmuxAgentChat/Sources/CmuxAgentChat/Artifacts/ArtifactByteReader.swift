import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads already-authorized artifact bytes and metadata from the local filesystem.
///
/// Authorization is intentionally outside this type. Callers must scope-check the
/// requested path before invoking these methods.
public struct ArtifactByteReader: Sendable {
    /// Filesystem/decoder failures surfaced by artifact RPC handlers.
    public enum Error: Swift.Error, Sendable {
        /// The scoped path no longer exists or cannot be statted.
        case fileNotFound
        /// The operation does not apply to this media type.
        case unsupportedMedia
    }

    /// Creates a byte reader.
    public init() {}

    /// Reads metadata for an already-authorized path.
    public func stat(path: String) throws -> ChatArtifactStat {
        let attributes = try attributes(path: path)
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let kind = kind(path: path, isDirectory: isDirectory)
        return ChatArtifactStat(
            exists: true,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt,
            kind: kind,
            mimeType: mimeType(path: path, isDirectory: isDirectory)
        )
    }

    /// Reads one clamped byte chunk for an already-authorized file path.
    public func fetch(path: String, offset: Int64, length: Int) throws -> ChatArtifactChunk {
        let stat = try stat(path: path)
        guard !stat.isDirectory else { throw Error.unsupportedMedia }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw Error.fileNotFound
        }
        defer { try? handle.close() }
        let totalSize = stat.size
        let clampedOffset = min(max(offset, 0), totalSize)
        try handle.seek(toOffset: UInt64(clampedOffset))
        let data = try handle.read(upToCount: max(0, length)) ?? Data()
        let endOffset = clampedOffset + Int64(data.count)
        return ChatArtifactChunk(
            data: data,
            offset: clampedOffset,
            totalSize: totalSize,
            eof: endOffset >= totalSize
        )
    }

    /// Generates a JPEG thumbnail for an already-authorized image path.
    public func thumbnail(path: String, maxDimension: Int) throws -> ChatArtifactThumbnail {
        guard kind(path: path, isDirectory: false) == .image else {
            throw Error.unsupportedMedia
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.fileNotFound
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Error.unsupportedMedia
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw Error.unsupportedMedia
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.unsupportedMedia
        }
        return ChatArtifactThumbnail(
            data: destinationData as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Lists up to 500 immediate children for an already-authorized directory.
    public func list(path: String) throws -> ChatArtifactDirectoryListing {
        let stat = try stat(path: path)
        guard stat.isDirectory else { throw Error.fileNotFound }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )
        let listed = try entries
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(500)
            .map { entry -> ChatArtifactDirectoryEntry in
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values.isDirectory ?? false
                return ChatArtifactDirectoryEntry(
                    name: entry.lastPathComponent,
                    isDirectory: isDirectory,
                    size: Int64(values.fileSize ?? 0),
                    kind: kind(path: entry.path, isDirectory: isDirectory)
                )
            }
        return ChatArtifactDirectoryListing(entries: listed)
    }

    /// Infers preview category from a path extension and directory flag.
    public func kind(path: String, isDirectory: Bool) -> ChatArtifactKind {
        if isDirectory { return .directory }
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return .binary
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    private func attributes(path: String) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw Error.fileNotFound
        }
    }

    private func mimeType(path: String, isDirectory: Bool) -> String? {
        guard !isDirectory,
              let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }
}
