import Foundation

/// Secrets REPL sessions typed into browser tabs, so a typed value stays
/// masked for every session that reads the tab, not only the one that
/// holds the secret.
///
/// A session's own secrets are redacted by that session
/// (``BrowserReplSecretStore``). Another session that drives the same tab
/// (`tabs.use`) does not hold them, so without this its reads of the field
/// (`inputValue`, `evaluate`, a screenshot) would return the value. The
/// driver records each secret it types, by tab, and masks the values other
/// sessions typed in every result, event and capture it hands a session;
/// the session masks them in everything else it hands JavaScript or prints
/// (fetch responses, files written and read back, output lines, errors).
/// The typing session keeps its own store's behavior (a TOTP code it typed
/// stays readable to it). A record lasts until its tab closes; when the
/// typing session leaves, its records mask for every session, including a
/// later session with the same name.
///
/// A record is kept per tab and distinct value, so sessions whose secrets
/// share a name, one session typing a name into several tabs, or typing a
/// name into a tab again with a new value never drop an earlier value: the
/// page may keep it (another field, its history, a hidden copy) until the
/// tab closes. The same value typed into the same tab again is one record.
/// Each value is
/// masked as typed, a literal under an internal key shown as
/// `<secret:name>`: a TOTP secret's typed value is its code, so no TOTP
/// rule (`totp`, or a name ending in `bu_2fa_code`) applies.
///
/// The registry is shared by every session and safe to use from any thread:
/// a session reads it off the main thread for its fetch responses, files
/// and output lines (``BrowserReplDriver/typedSecretRedaction()``).
public final class BrowserReplTypedSecrets: @unchecked Sendable {
    private struct Typed {
        let key: Int
        let tab: String
        let name: String
        let value: String
        let domains: [BrowserReplDomainPattern]
        /// The session that typed it, while that session lasts.
        var typist: String?
    }

    /// Readers are sessions; past this many cached stores the cache starts over.
    static let maximumCachedReaders = 64

    private let lock = NSLock()
    private var entries: [Typed] = []
    private var nextKey = 0
    /// The redaction stores built since the last change, by reader; emptied
    /// on every change.
    private var stores: [String: BrowserReplSecretStore?] = [:]

    public init() {}

    public var isEmpty: Bool { lock.withLock { entries.isEmpty } }

    /// `typist` typed secret `name`'s `value` into `tab`.
    ///
    /// The driver records a value before it types it. Every reader masks
    /// every record, so the records are bounded
    /// (``BrowserReplSecretStore/maximumTypedValues``, each value at most
    /// ``BrowserReplSecretStore/maximumValueBytes``): past that the value is
    /// refused (`invalid`) and must not be typed, since a record is never
    /// dropped while its tab may still show the value. A record replaces
    /// only one of the same value under `name` in `tab`, typed by `typist`
    /// or by a session that left (a kept tab a later session of the same
    /// task types into again); a new value never replaces an earlier one.
    public func record(tab: String, name: String, value: String, domains: [BrowserReplDomainPattern], typist: String) throws {
        try BrowserReplSecretStore.checkTypedValue(value, domains: domains)
        try lock.withLock {
            let replaced = { (entry: Typed) in
                entry.tab == tab && entry.name == name && entry.value == value && (entry.typist == typist || entry.typist == nil)
            }
            if !entries.contains(where: replaced), entries.count >= BrowserReplSecretStore.maximumTypedValues {
                throw BrowserReplSecretStore.tooManyTypedValues
            }
            entries.removeAll(where: replaced)
            nextKey += 1
            entries.append(Typed(key: nextKey, tab: tab, name: name, value: value, domains: domains, typist: typist))
            stores.removeAll()
        }
    }

    /// `sessionID` ended: what it typed masks for every session from now on.
    public func sessionLeft(_ sessionID: String) {
        lock.withLock {
            var changed = false
            for index in entries.indices where entries[index].typist == sessionID {
                entries[index].typist = nil
                changed = true
            }
            if changed { stores.removeAll() }
        }
    }

    /// `tab` closed, and its typed values with it.
    public func tabClosed(_ tab: String) {
        lock.withLock {
            let before = entries.count
            entries.removeAll { $0.tab == tab }
            if entries.count != before { stores.removeAll() }
        }
    }

    private func entriesLocked(forReader sessionID: String) -> [Typed] {
        entries.filter { $0.typist != sessionID }
    }

    /// A store that redacts the values other sessions typed, for what
    /// `sessionID` reads, or `nil` when there are none. The same store is
    /// returned until the typed values change, so its matchers are built
    /// once per change, not per result or event.
    public func redaction(forReader sessionID: String) -> BrowserReplSecretStore? {
        lock.withLock {
            if let cached = stores[sessionID] { return cached }
            let visible = entriesLocked(forReader: sessionID)
            var built: BrowserReplSecretStore?
            if !visible.isEmpty {
                let store = BrowserReplSecretStore()
                // `record` refuses what `setLiteral` would (the same value
                // and count bounds), so none is refused here.
                for entry in visible {
                    try? store.setLiteral(key: "typed-\(entry.key)", maskName: entry.name, value: entry.value, domains: entry.domains)
                }
                built = store.isEmpty ? nil : store
            }
            if stores.count >= Self.maximumCachedReaders { stores.removeAll() }
            stores[sessionID] = .some(built)
            return built
        }
    }

    /// The mark of the values `sessionID` would mask now, taken with a
    /// capture's masks, for ``typedSince(_:forReader:)``.
    public func captureMark(forReader sessionID: String) -> Int {
        lock.withLock { nextKey }
    }

    /// Whether another session recorded a value `sessionID` must not see
    /// since `mark` (``captureMark(forReader:)``), in any tab. The driver
    /// records a value before it types it, so a value a capture's pixels can
    /// show was recorded before the capture ended: a capture that finds one
    /// recorded since its masks were taken is refused.
    public func typedSince(_ mark: Int, forReader sessionID: String) -> Bool {
        lock.withLock { entriesLocked(forReader: sessionID).contains { $0.key > mark } }
    }

    /// The values other sessions typed, as the driver's `secretMasks`
    /// (`[{ value, domains }]`), for a capture `sessionID` takes.
    public func captureMasks(forReader sessionID: String) -> [[String: Any]] {
        lock.withLock { entriesLocked(forReader: sessionID) }.map { ["value": $0.value, "domains": $0.domains.map(\.json)] }
    }
}
