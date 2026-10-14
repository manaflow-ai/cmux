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
/// sessions typed in every result, event and capture it hands a session.
/// The typing session keeps its own store's behavior (a TOTP code it typed
/// stays readable to it). A record lasts until its tab closes; when the
/// typing session leaves, its records mask for every session, including a
/// later session with the same name.
///
/// A record is kept per tab, typing session and secret name, so sessions
/// whose secrets share a name, or one session typing a name into several
/// tabs, never replace each other's values; a session that types the same
/// name into the same tab again replaces its earlier value. Each value is
/// masked as typed, a literal under an internal key shown as
/// `<secret:name>`: a TOTP secret's typed value is its code, so no TOTP
/// rule (`totp`, or a name ending in `bu_2fa_code`) applies.
public struct BrowserReplTypedSecrets {
    private struct Typed {
        let key: Int
        let tab: String
        let name: String
        let value: String
        let domains: [BrowserReplDomainPattern]
        /// The session that typed it, while that session lasts.
        var typist: String?
    }

    /// The redaction stores built since the last change, by reader. Replaced
    /// (never mutated in place) on every change, so a copy of this value
    /// never reads a store built for another copy's records.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: BrowserReplSecretStore?] = [:]
        /// Readers are sessions; past this many the cache starts over.
        static let maximumReaders = 64

        func store(forReader reader: String, build: () -> BrowserReplSecretStore?) -> BrowserReplSecretStore? {
            if let cached = lock.withLock({ stores[reader] }) { return cached }
            let built = build()
            lock.withLock {
                if stores.count >= Self.maximumReaders { stores.removeAll() }
                stores[reader] = .some(built)
            }
            return built
        }
    }

    private var entries: [Typed] = []
    private var nextKey = 0
    private var cache = Cache()

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// `typist` typed secret `name`'s `value` into `tab`.
    public mutating func record(tab: String, name: String, value: String, domains: [BrowserReplDomainPattern], typist: String) {
        entries.removeAll { $0.tab == tab && $0.name == name && $0.typist == typist }
        nextKey += 1
        entries.append(Typed(key: nextKey, tab: tab, name: name, value: value, domains: domains, typist: typist))
        cache = Cache()
    }

    /// `sessionID` ended: what it typed masks for every session from now on.
    public mutating func sessionLeft(_ sessionID: String) {
        var changed = false
        for index in entries.indices where entries[index].typist == sessionID {
            entries[index].typist = nil
            changed = true
        }
        if changed { cache = Cache() }
    }

    /// `tab` closed, and its typed values with it.
    public mutating func tabClosed(_ tab: String) {
        let before = entries.count
        entries.removeAll { $0.tab == tab }
        if entries.count != before { cache = Cache() }
    }

    private func entries(forReader sessionID: String) -> [Typed] {
        entries.filter { $0.typist != sessionID }
    }

    /// A store that redacts the values other sessions typed, for what
    /// `sessionID` reads, or `nil` when there are none. The same store is
    /// returned until the typed values change, so its patterns compile once
    /// per change, not per result or event. It is safe to use off the main
    /// thread.
    public func redaction(forReader sessionID: String) -> BrowserReplSecretStore? {
        cache.store(forReader: sessionID) {
            let visible = entries(forReader: sessionID)
            guard !visible.isEmpty else { return nil }
            let store = BrowserReplSecretStore()
            for entry in visible {
                store.setLiteral(key: "typed-\(entry.key)", maskName: entry.name, value: entry.value, domains: entry.domains)
            }
            return store.isEmpty ? nil : store
        }
    }

    /// The values other sessions typed, as the driver's `secretMasks`
    /// (`[{ value, domains }]`), for a capture `sessionID` takes.
    public func captureMasks(forReader sessionID: String) -> [[String: Any]] {
        entries(forReader: sessionID).map { ["value": $0.value, "domains": $0.domains.map(\.json)] }
    }
}
