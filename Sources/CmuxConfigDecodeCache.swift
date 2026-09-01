import CryptoKit
import Foundation

/// Bounded, thread-safe cache for config decode results keyed by file content
/// and its filesystem revision.
// SAFETY: NSCache synchronizes its storage internally, and each Entry holds
// immutable value-type snapshots. The cache is shared by synchronous registry
// loads running on arbitrary utility threads.
final class CmuxConfigDecodeCache: @unchecked Sendable {
    final class Entry: NSObject {
        let config: CmuxConfigFile?
        let failureMessage: String?

        init(config: CmuxConfigFile?, failureMessage: String?) {
            self.config = config
            self.failureMessage = failureMessage
        }
    }

    private let entries: NSCache<NSString, Entry>

    init(countLimit: Int = 128) {
        let entries = NSCache<NSString, Entry>()
        entries.countLimit = countLimit
        self.entries = entries
    }

    func key(path: String, data: Data, fileManager: FileManager) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? UInt64(data.count)
        let modificationDate = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(path)|\(fileSize)|\(modificationDate)|\(digest)"
    }

    func entry(for key: String) -> Entry? {
        entries.object(forKey: key as NSString)
    }

    func insert(config: CmuxConfigFile?, failureMessage: String?, for key: String) {
        entries.setObject(
            Entry(config: config, failureMessage: failureMessage),
            forKey: key as NSString
        )
    }
}
