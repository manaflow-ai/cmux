import Foundation

final class DirectoryEnumerationRecordingFileManager: FileManager {
    private(set) var enumeratedDirectoryPaths: [String] = []

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        enumeratedDirectoryPaths.append(url.standardizedFileURL.path)
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
