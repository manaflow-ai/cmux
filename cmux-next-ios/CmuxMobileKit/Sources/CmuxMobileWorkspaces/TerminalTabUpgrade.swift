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
/// Writes are ordered per tab (round 11 A5): a write names the ticket taken
/// when its frame was captured, and is dropped when a newer frame was written
/// meanwhile or the tab's file was removed (a closed tab) after the ticket.
public struct TerminalFrameStore: Sendable {
    public let directory: URL
    private let ledger = Ledger()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Per tab: the last ticket issued, the newest ticket written, and the
    /// ticket current when the file was last removed. Writes and removes
    /// happen under its lock, so they cannot interleave.
    private final class Ledger: @unchecked Sendable {
        let lock = NSLock()
        var issued: [String: Int] = [:]
        var written: [String: Int] = [:]
        var removed: [String: Int] = [:]
    }

    /// A ticket for a frame captured now, to pass to `save(_:for:ticket:)`
    /// once it is rendered.
    public func ticket(for tabID: String) -> Int {
        ledger.lock.withLock {
            let next = (ledger.issued[tabID] ?? 0) + 1
            ledger.issued[tabID] = next
            return next
        }
    }

    /// Writes a frame captured under `ticket`, unless a newer frame was
    /// written or the tab's file was removed since.
    public func save(_ data: Data, for tabID: String, ticket: Int) {
        ledger.lock.withLock {
            guard ticket > (ledger.written[tabID] ?? 0), ticket > (ledger.removed[tabID] ?? 0) else { return }
            ledger.written[tabID] = ticket
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url(for: tabID), options: .atomic)
        }
    }

    /// `Caches/cmux-mobile-terminal-frames`.
    public static var standard: TerminalFrameStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TerminalFrameStore(directory: caches.appendingPathComponent("cmux-mobile-terminal-frames", isDirectory: true))
    }

    /// One file per tab; the id is reduced to safe file name characters.
    public func url(for tabID: String) -> URL {
        let safe = String(tabID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        return directory.appendingPathComponent(safe.isEmpty ? "_" : safe).appendingPathExtension("jpg")
    }

    /// Writes a frame captured now.
    public func save(_ data: Data, for tabID: String) {
        save(data, for: tabID, ticket: ticket(for: tabID))
    }

    public func load(_ tabID: String) -> Data? {
        try? Data(contentsOf: url(for: tabID))
    }

    /// Removes the tab's file; frames captured before this are never written.
    public func remove(_ tabID: String) {
        ledger.lock.withLock {
            ledger.removed[tabID] = ledger.issued[tabID] ?? 0
            try? FileManager.default.removeItem(at: url(for: tabID))
        }
    }
}
