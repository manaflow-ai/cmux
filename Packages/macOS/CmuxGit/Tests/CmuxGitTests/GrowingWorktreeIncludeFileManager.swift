import Foundation

// This test-only FileManager is used by one task; mutable enumeration state is
// confined to that serialized call path.
final class GrowingWorktreeIncludeFileManager: FileManager, @unchecked Sendable {
    private let targetDirectory: URL
    private let fileToGrow: URL
    private var targetEnumerationCount = 0

    init(targetDirectory: URL, fileToGrow: URL) {
        self.targetDirectory = targetDirectory.standardizedFileURL
        self.fileToGrow = fileToGrow
        super.init()
    }

    override func enumerator(atPath path: String) -> DirectoryEnumerator? {
        if URL(fileURLWithPath: path).standardizedFileURL == targetDirectory {
            targetEnumerationCount += 1
            if targetEnumerationCount == 2,
               let handle = try? FileHandle(forWritingTo: fileToGrow) {
                try? handle.truncate(atOffset: 51 * 1024 * 1024 * 1024)
                try? handle.close()
            }
        }
        return super.enumerator(atPath: path)
    }
}
