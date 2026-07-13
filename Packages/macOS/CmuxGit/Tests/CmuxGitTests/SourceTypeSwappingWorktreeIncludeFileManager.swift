import Foundation

// This test-only FileManager mutates one source item from a symlink to a regular
// file at the old snapshot-to-copy boundary; the serialized test is its only caller.
final class SourceTypeSwappingWorktreeIncludeFileManager: FileManager, @unchecked Sendable {
    private let sourceItem: URL
    private let triggerDirectory: URL
    private let replacementByteCount: Int
    private var didSwap = false

    init(sourceItem: URL, triggerDirectory: URL, replacementByteCount: Int) {
        self.sourceItem = sourceItem.standardizedFileURL
        self.triggerDirectory = triggerDirectory.standardizedFileURL
        self.replacementByteCount = replacementByteCount
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        if !didSwap,
           URL(fileURLWithPath: path).standardizedFileURL == triggerDirectory {
            didSwap = true
            try? removeItem(at: sourceItem)
            _ = createFile(
                atPath: sourceItem.path,
                contents: Data(repeating: 0x41, count: replacementByteCount)
            )
        }
        return super.fileExists(atPath: path)
    }
}
