import Foundation

/// Records eager directory materialization so scanner tests can enforce streaming traversal.
final class DirectoryEnumerationRecordingFileManager: FileManager, @unchecked Sendable {
    private(set) var eagerDirectoryReadCount = 0

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        eagerDirectoryReadCount += 1
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
