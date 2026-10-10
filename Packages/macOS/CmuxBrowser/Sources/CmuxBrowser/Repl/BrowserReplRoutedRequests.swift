/// Dialogs and file choosers of one tab that wait for a REPL session, each
/// bound to the session it was routed to (``BrowserReplTabOwnership/recipient(for:)``).
///
/// Only that session may answer one: another session driving the same tab
/// gets nothing from ``take(id:sessionID:)`` and the request stays open.
/// When the owning session leaves the tab, ``removeAll(ownedBy:)`` hands
/// back its requests so the caller can dismiss them, and the page is never
/// left blocked on a request nobody can answer.
public struct BrowserReplRoutedRequests<Respond> {
    private var entries: [String: (owner: String, respond: Respond)] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Records request `id`, routed to `owner`.
    public mutating func add(id: String, owner: String, respond: Respond) {
        entries[id] = (owner, respond)
    }

    /// Removes and returns request `id`'s responder when `sessionID` owns it;
    /// `nil` when it is gone or another session owns it (it stays open).
    public mutating func take(id: String, sessionID: String) -> Respond? {
        guard let entry = entries[id], entry.owner == sessionID else { return nil }
        entries.removeValue(forKey: id)
        return entry.respond
    }

    /// Request `id`'s responder when `sessionID` owns it, left in place.
    public func value(id: String, sessionID: String) -> Respond? {
        guard let entry = entries[id], entry.owner == sessionID else { return nil }
        return entry.respond
    }

    /// Removes and returns the responders of `sessionID`'s requests.
    public mutating func removeAll(ownedBy sessionID: String) -> [Respond] {
        let owned = entries.filter { $0.value.owner == sessionID }
        for id in owned.keys { entries.removeValue(forKey: id) }
        return owned.values.map(\.respond)
    }

    /// Removes and returns every responder.
    public mutating func removeAll() -> [Respond] {
        defer { entries.removeAll() }
        return entries.values.map(\.respond)
    }
}
