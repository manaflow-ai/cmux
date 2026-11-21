import Foundation

/// What each terminal tab's composer holds while the tab has no host: a host goes and comes back
/// on a reconnect (the live session replacing the connecting placeholder, every host dropped when
/// the live coordinator changes), a cooled tab, and a cold launch, and each new host starts with an
/// empty composer. A draft waits here, by the tab's account, Mac and surface, and its next host
/// takes it (Leo, 2026-11-21: "my drafted message on ios in the fucking round composer got lost").
///
/// Kept on disk (`UserDefaults`) so a relaunch keeps it too; capped in bytes where it is written,
/// oldest dropped first. A draft cleared in the composer (sent or deleted) is removed.
public struct TerminalComposerDrafts {
    /// Bytes of draft text kept on disk at most.
    public static let byteLimit = 64 * 1024
    static let defaultsKey = "terminal.composerDrafts.v1"

    private struct Entry: Codable, Equatable {
        var accountID: String
        var macID: String
        var surfaceID: String
        var text: String
        var savedAt: Date

        func matches(_ key: TerminalFrameKey) -> Bool {
            accountID == key.accountID && macID == key.macID && surfaceID == key.surfaceID
        }
    }

    private var entries: [Entry]
    private let defaults: UserDefaults?
    private let now: () -> Date

    /// `defaults` nil keeps drafts in memory only (tests, a store with no account).
    public init(defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// The draft for `key`, or nil. It stays until `keep` replaces or clears it.
    public func draft(for key: TerminalFrameKey) -> String? {
        entries.first { $0.matches(key) }?.text
    }

    /// Keeps `text` for `key`; an empty text removes the draft.
    public mutating func keep(_ text: String, for key: TerminalFrameKey) {
        let index = entries.firstIndex { $0.matches(key) }
        if text.isEmpty {
            guard let index else { return }
            entries.remove(at: index)
        } else {
            if let index, entries[index].text == text { return }
            if let index { entries.remove(at: index) }
            entries.append(Entry(accountID: key.accountID, macID: key.macID, surfaceID: key.surfaceID,
                                 text: text, savedAt: now()))
        }
        save()
    }

    /// Drops the draft of a tab that closed.
    public mutating func remove(_ key: TerminalFrameKey) { keep("", for: key) }

    private mutating func save() {
        // Oldest first out while over the cap; the newest draft always stays.
        var total = entries.reduce(0) { $0 + $1.text.utf8.count }
        while total > Self.byteLimit, entries.count > 1 {
            total -= entries.removeFirst().text.utf8.count
        }
        guard let defaults else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
