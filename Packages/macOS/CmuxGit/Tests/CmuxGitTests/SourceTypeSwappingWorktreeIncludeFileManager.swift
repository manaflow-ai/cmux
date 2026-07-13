import Foundation

// Mutates one source item at the snapshot-to-copy boundary; the serialized test
// is its only caller.
final class SourceTypeSwappingWorktreeIncludeFileManager: @unchecked Sendable {
    private let sourceItem: URL
    private let replacementByteCount: Int
    private var didSwap = false

    init(sourceItem: URL, replacementByteCount: Int) {
        self.sourceItem = sourceItem.standardizedFileURL
        self.replacementByteCount = replacementByteCount
    }

    func swapIfMatching(_ inspectedItem: URL) {
        guard !didSwap,
              inspectedItem.standardizedFileURL == sourceItem else { return }
        didSwap = true
        try? FileManager.default.removeItem(at: sourceItem)
        _ = FileManager.default.createFile(
            atPath: sourceItem.path,
            contents: Data(repeating: 0x41, count: replacementByteCount)
        )
    }
}
