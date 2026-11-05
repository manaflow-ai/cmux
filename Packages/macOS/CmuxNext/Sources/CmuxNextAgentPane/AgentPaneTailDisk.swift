import CmuxNextCompat
public import CmuxNextSettings
import CryptoKit
public import Foundation

/// The disk tier under ``AgentPaneTailCache``: each chat's kept tail as one small JSON file, so a
/// chat opened from the sidebar or a link draws its last read rows before acpmux's attach answers,
/// also right after the app restarted, when the memory tier is empty (Leo, 2026-11-05: "there's
/// stuff opening up subagents or opening up other sessions. Those need to be fast. There's no
/// reason for them to have a delay, even under load.").
///
/// Every disk touch runs on one serial utility queue, never on the main thread: a save is handed
/// a value and encodes on the queue, a read is awaited holding no thread. Saves of one chat
/// coalesce (a save a newer one replaced before it ran is skipped), and reads queue behind the
/// saves made before them, so a read sees the newest tail handed over.
///
/// Bounded as the memory tier is: at most ``AgentPaneTailCache/chats`` files (the least recently
/// written go first) of at most ``AgentPaneTailCache/bytes`` each, so about 20 MiB in the worst
/// case. A file over the bound, or one that does not decode as a tail, is removed and read as none.
/// File names are a hash of the session id, so no id names a path. ``clear()`` (sign-out) removes
/// the whole folder.
public nonisolated final class AgentPaneTailDisk: Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.tail-disk", qos: .utility)
    /// The newest save's number per file name: a queued save with an older one does nothing.
    private let newest = Mutex<[String: UInt64]>([:])
    private let counter = Mutex<UInt64>(0)
    private let limitFiles: Int
    private let limitBytes: Int

    public init(directory: URL, files: Int = AgentPaneTailCache.chats, bytes: Int = AgentPaneTailCache.bytes) {
        self.directory = directory
        limitFiles = files
        limitBytes = bytes
    }

    /// The file chat `sessionId`'s tail is kept in.
    func url(for sessionId: String) -> URL {
        let digest = SHA256.hash(data: Data(sessionId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }

    /// Red stub: keeps nothing.
    public func write(_ tail: JSONValue?, for sessionId: String) {}
    public func read(_ sessionId: String) async -> JSONValue? { nil }
    public func clear() {}
    public func settled() async {}
}
