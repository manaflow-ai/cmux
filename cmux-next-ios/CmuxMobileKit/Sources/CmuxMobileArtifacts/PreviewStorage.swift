import Foundation

/// A capacity failure retains the remote reference for actions that need no local copy.
public struct PreviewInsufficientSpace: Error, LocalizedError, Sendable {
    public let path: String
    public let size: Int64

    public var errorDescription: String? {
        let name = (path as NSString).lastPathComponent
        let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "Not enough free space on this iPhone to preview \(name) (\(formatted))"
    }
}

/// A free-space reserve, never a file-size limit. It leaves room for other app/OS
/// writes between capacity observations; any file fitting beside it can download.
enum PreviewStorage {
    static let reserveBytes: Int64 = 64 << 20
    typealias Capacity = @Sendable (URL) throws -> Int64

    static func availableCapacity(at url: URL) throws -> Int64 {
        let folder = url.deletingLastPathComponent()
        #if os(iOS) || os(macOS)
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw ArtifactUnavailable("Couldn't check free space on this iPhone.")
        }
        return bytes
        #else
        let values = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        guard let bytes = values[.systemFreeSize] as? NSNumber else {
            throw ArtifactUnavailable("Couldn't check free space on this device.")
        }
        return bytes.int64Value
        #endif
    }

    static func check(_ destination: URL, path: String, size: Int64, remaining: Int64,
                      capacity: Capacity) throws {
        let free = try capacity(destination)
        guard free >= reserveBytes, remaining <= free - reserveBytes else {
            throw PreviewInsufficientSpace(path: path, size: size)
        }
    }
}
