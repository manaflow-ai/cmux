import Foundation

// This test-only FileManager is used by one task; mutable enumeration state is
// confined to that serialized call path.
final class GrowingWorktreeIncludeFileManager: FileManager, @unchecked Sendable {
    private let targetDirectory: URL
    private let fileToGrow: URL
    private let grownByteCount: UInt64
    private var targetEnumerationCount = 0

    init(targetDirectory: URL, fileToGrow: URL, grownByteCount: UInt64) {
        self.targetDirectory = targetDirectory.standardizedFileURL
        self.fileToGrow = fileToGrow
        self.grownByteCount = grownByteCount
        super.init()
    }

    override func enumerator(atPath path: String) -> DirectoryEnumerator? {
        if URL(fileURLWithPath: path).standardizedFileURL == targetDirectory {
            targetEnumerationCount += 1
            if targetEnumerationCount == 2,
               let handle = try? FileHandle(forWritingTo: fileToGrow) {
                try? handle.truncate(atOffset: grownByteCount)
                try? handle.close()
            }
        }
        return super.enumerator(atPath: path)
    }
}
