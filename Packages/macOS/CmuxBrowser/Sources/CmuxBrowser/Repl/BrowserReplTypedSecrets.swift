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
/// later session with the same name. Under one name the latest value typed
/// is the one masked.
public struct BrowserReplTypedSecrets {
    private struct Typed {
        let tab: String
        let name: String
        let value: String
        let domains: [BrowserReplDomainPattern]
        var typist: String?
    }

    private var entries: [Typed] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// `typist` typed secret `name`'s `value` into `tab`.
    public mutating func record(tab: String, name: String, value: String, domains: [BrowserReplDomainPattern], typist: String) {
        entries.removeAll { $0.tab == tab && $0.name == name }
        entries.append(Typed(tab: tab, name: name, value: value, domains: domains, typist: typist))
    }

    /// `sessionID` ended: what it typed masks for every session from now on.
    public mutating func sessionLeft(_ sessionID: String) {
        for index in entries.indices where entries[index].typist == sessionID {
            entries[index].typist = nil
        }
    }

    /// `tab` closed, and its typed values with it.
    public mutating func tabClosed(_ tab: String) {
        entries.removeAll { $0.tab == tab }
    }

    private func entries(forReader sessionID: String) -> [Typed] {
        entries.filter { $0.typist != sessionID }
    }

    /// A store that redacts the values other sessions typed, for what
    /// `sessionID` reads, or `nil` when there are none.
    public func redaction(forReader sessionID: String) -> BrowserReplSecretStore? {
        let visible = entries(forReader: sessionID)
        guard !visible.isEmpty else { return nil }
        let store = BrowserReplSecretStore()
        for entry in visible {
            try? store.set(name: entry.name, value: entry.value, domains: entry.domains.map(\.raw), totp: false, title: "typed secret")
        }
        return store.isEmpty ? nil : store
    }

    /// The values other sessions typed, as the driver's `secretMasks`
    /// (`[{ value, domains }]`), for a capture `sessionID` takes.
    public func captureMasks(forReader sessionID: String) -> [[String: Any]] {
        entries(forReader: sessionID).map { ["value": $0.value, "domains": $0.domains.map(\.json)] }
    }
}
