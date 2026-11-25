#if canImport(CmuxMobileLinkFFI)
import CmuxMobileChief
import CmuxMobileLinkFFI
import CmuxMobileModel
import Foundation
import os

/// The phone's own read-first store (Rust `PhoneReadStore`, cmux-mobile-core `read_store`): what a
/// surface last showed, per account, Mac and surface, so a cold launch draws it before the Mac
/// answers. Swift only names the directory and binds; the key, bounds, atomic write and eviction
/// are Rust's. One directory in Application Support (readable after first unlock, not in
/// backups), inside this app's own container, so every dev build's copy is its own. Sign-out
/// clears it (``AgentChatsMemory/removeAll()``).
public final class PhoneReadFirst: AgentChatsDisk, @unchecked Sendable {
    /// The Agent Chats list's surface name in the store's key.
    static let agentChatsKind = "agent_chats"

    public static let standard: PhoneReadFirst? = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PhoneReadFirst(directory: base.appending(path: "cmux-mobile-read-first", directoryHint: .isDirectory))
    }()

    private let store: PhoneReadStore
    /// Writes and removals run in order here, never on the main thread.
    private let queue = DispatchQueue(label: "dev.cmux.mobile.read-first", qos: .utility)
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "read-first")

    /// The store on `directory`: 64 entries of at most 256 KiB (Rust refuses larger).
    public init?(directory: URL, maxEntries: UInt32 = 64, maxValueBytes: UInt32 = 256 * 1024) {
        let manager = FileManager.default
        let path = directory.path(percentEncoded: false)
        if !manager.fileExists(atPath: path) {
            // New entry files take the directory's protection class.
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try? excluded.setResourceValues(values)
        }
        do {
            store = try PhoneReadStore.open(directory: path, maxEntries: maxEntries, maxValueBytes: maxValueBytes)
        } catch {
            Self.log.error("read-first store did not open: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Every Agent Chats list opened draws the account's stored first page at once.
    @MainActor public static func installAgentChats() {
        guard let standard else { return }
        AgentChatsMemory.shared.persist(to: standard, accountID: { ChiefSources.shared.activeUserID })
    }

    public func read(account: String, macID: String) -> Data? {
        store.get(key: key(account, macID)).map { Data($0) }
    }

    public func write(_ data: Data, account: String, macID: String) {
        let key = key(account, macID)
        queue.async { [store] in
            do { try store.put(key: key, value: data) } catch {
                Self.log.error("read-first write refused: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func removeAll() {
        // In order after any write already queued, so nothing written before sign-out stays.
        queue.async { [store] in
            do { try store.removeAll() } catch {
                Self.log.error("read-first clear failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func key(_ account: String, _ macID: String) -> PhoneReadKey {
        PhoneReadKey(scope: account, device: macID, kind: Self.agentChatsKind)
    }
}
#endif
