import CryptoKit
import Foundation
import os

/// Bounded, thread-safe cache for config decode results keyed by file content
/// and its filesystem revision.
// SAFETY: NSCache synchronizes its storage internally, and each Entry holds
// immutable value-type snapshots. The cache is shared by synchronous registry
// loads running on arbitrary utility threads.
final class CmuxConfigDecodeCache: @unchecked Sendable {
    final class Entry: NSObject {
        let config: CmuxConfigFile?

        init(config: CmuxConfigFile?) {
            self.config = config
        }
    }

    enum Lookup {
        case hit(Entry)
        case miss(isFirstLoader: Bool)
    }

    private struct State {
        var inFlightKeys: Set<String> = []
    }

    private let entries: NSCache<NSString, Entry>
    // Lock carve-out: only the in-flight ownership compare-and-set is guarded;
    // JSONC parsing runs outside the lock and never blocks other cache users.
    private let state = OSAllocatedUnfairLock(initialState: State())

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

    /// Returns a cached entry or claims ownership of a cold revision. A
    /// follower may decode independently, but only the first loader publishes
    /// a failure; this prevents concurrent misses from duplicating diagnostics.
    func lookupOrClaim(_ key: String) -> Lookup {
        if let entry = entries.object(forKey: key as NSString) {
            return .hit(entry)
        }
        return state.withLock { state in
            if let entry = entries.object(forKey: key as NSString) {
                return .hit(entry)
            }
            return .miss(isFirstLoader: state.inFlightKeys.insert(key).inserted)
        }
    }

    func insert(config: CmuxConfigFile?, for key: String) {
        entries.setObject(
            Entry(config: config),
            forKey: key as NSString
        )
    }

    func finishLoading(_ key: String, isOwner: Bool) {
        guard isOwner else { return }
        state.withLock { state in
            state.inFlightKeys.remove(key)
            return ()
        }
    }
}
