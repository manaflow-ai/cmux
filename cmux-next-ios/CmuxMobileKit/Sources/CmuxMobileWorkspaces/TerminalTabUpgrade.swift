import Foundation

/// Which terminal tabs still run on a placeholder session and must move to
/// their live session once one exists (design/terminal R1-0). A page built
/// before live data (a launch restore opens the workspace before the link and
/// the workspace tree are up) gets the connecting placeholder; nothing asked
/// for that page again, so it said "Connecting to <Mac>…" until the user left
/// and reopened the workspace. Every live-data change now offers the
/// placeholder tabs their live session. Portable rules, unit tested.
public struct TerminalTabUpgrade: Sendable {
    /// Tabs whose page shows a placeholder, with the workspace they belong to.
    public private(set) var placeholders: [String: String] = [:]

    public init() {}

    /// A tab's host was built, on a live session or a placeholder.
    public mutating func built(tabID: String, workspaceID: String, live: Bool) {
        placeholders[tabID] = live ? nil : workspaceID
    }

    /// The tab's host went away (closed, cooled, reset).
    public mutating func removed(tabID: String) {
        placeholders[tabID] = nil
    }

    public mutating func reset() {
        placeholders = [:]
    }

    /// Live data changed: the placeholder tabs that now have a live session
    /// (`hasLiveSession`), in a stable order.
    public func upgradable(hasLiveSession: (String) -> Bool) -> [String] {
        placeholders.keys.sorted().filter(hasLiveSession)
    }
}

/// The last frame of each terminal tab, kept on disk so a cold launch that
/// restores a tab shows it (dimmed, under "Connecting…") instead of skeleton
/// rows until the Mac's terminal is attached (design/terminal R1-0).
///
/// Stable identity for a terminal preview. Surface IDs repeat across Macs and
/// accounts, so neither a surface ID nor a tab ID is sufficient on its own.
public struct TerminalFrameKey: Hashable, Sendable {
    public let accountID: String
    public let macID: String
    public let surfaceID: String

    public init(accountID: String, macID: String, surfaceID: String) {
        self.accountID = accountID
        self.macID = macID
        self.surfaceID = surfaceID
    }

    /// Each component is encoded separately so distinct identities cannot
    /// collide after being reduced to a filename.
    fileprivate var fileComponent: String {
        [accountID, macID, surfaceID].map(Self.encode).joined(separator: "-")
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Frame identity retained after a tab's live host is cooled. Shared by the
/// terminal host lifecycle and its portable regression tests.
public struct TerminalFrameLifecycle {
    private var cooledFrameKeys: [String: TerminalFrameKey] = [:]

    public init() {}

    public mutating func hostBuilt(tabID: String) {
        cooledFrameKeys[tabID] = nil
    }

    public mutating func cooled(tabID: String, frameKey: TerminalFrameKey) {
        cooledFrameKeys[tabID] = frameKey
    }

    /// Remove both copies of the frame using the original host's identity,
    /// even after cooling has removed that host.
    public mutating func release(tabID: String, hostFrameKey: TerminalFrameKey?,
                                 removeFrame: (TerminalFrameKey) -> Void) {
        let cooledKey = cooledFrameKeys.removeValue(forKey: tabID)
        if let key = hostFrameKey ?? cooledKey { removeFrame(key) }
    }

    public mutating func reset() {
        cooledFrameKeys = [:]
    }
}

/// Writes are ordered per frame key (round 11 A5): a write names the ticket
/// taken when its frame was captured, and is dropped when a newer frame was
/// written meanwhile or the frame's file was removed after the ticket.
public struct TerminalFrameStore: Sendable {
    public let directory: URL
    private let ledger = Ledger()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Per frame key: the last ticket issued, the newest ticket written, and the
    /// ticket current when the file was last removed. Writes and removes
    /// happen under its lock, so they cannot interleave.
    private final class Ledger: @unchecked Sendable {
        let lock = NSLock()
        var issued: [TerminalFrameKey: Int] = [:]
        var written: [TerminalFrameKey: Int] = [:]
        var removed: [TerminalFrameKey: Int] = [:]
    }

    /// A ticket for a frame captured now, to pass to `save(_:for:ticket:)`
    /// once it is rendered.
    public func ticket(for key: TerminalFrameKey) -> Int {
        ledger.lock.withLock {
            let next = (ledger.issued[key] ?? 0) + 1
            ledger.issued[key] = next
            return next
        }
    }

    /// Writes a frame captured under `ticket`, unless a newer frame was
    /// written or the tab's file was removed since.
    public func save(_ data: Data, for key: TerminalFrameKey, ticket: Int) {
        ledger.lock.withLock {
            guard ticket > (ledger.written[key] ?? 0), ticket > (ledger.removed[key] ?? 0) else { return }
            ledger.written[key] = ticket
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url(for: key), options: .atomic)
        }
    }

    /// `Caches/cmux-mobile-terminal-frames`.
    public static var standard: TerminalFrameStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TerminalFrameStore(directory: caches.appendingPathComponent("cmux-mobile-terminal-frames", isDirectory: true))
    }

    /// One file per account/Mac/surface identity. Legacy tab-ID filenames are
    /// deliberately never consulted because they cannot be assigned safely.
    public func url(for key: TerminalFrameKey) -> URL {
        directory.appendingPathComponent("v1-\(key.fileComponent)").appendingPathExtension("jpg")
    }

    /// Writes a frame captured now.
    public func save(_ data: Data, for key: TerminalFrameKey) {
        save(data, for: key, ticket: ticket(for: key))
    }

    public func load(_ key: TerminalFrameKey) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    /// Removes the tab's file; frames captured before this are never written.
    public func remove(_ key: TerminalFrameKey) {
        ledger.lock.withLock {
            ledger.removed[key] = ledger.issued[key] ?? 0
            try? FileManager.default.removeItem(at: url(for: key))
        }
    }
}
