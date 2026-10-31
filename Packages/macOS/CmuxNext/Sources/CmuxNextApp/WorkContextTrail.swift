/// The terminals and agent chats a person focused, newest first (NEW-WORK-INHERITS-CONTEXT): what a
/// new terminal or agent chat copies its folder from, and what a new chat copies its harness,
/// model, effort and mode from.
///
/// The rule, first match wins:
/// 1. The tab the person is in (`current`), when it is a terminal or an agent chat.
/// 2. The most recently focused terminal or chat of the target workspace.
/// 3. Only when that workspace holds no terminal or chat of its own (a browser-only or empty
///    workspace): the most recently focused one of the same window.
/// 4. Nothing: the caller's own fallback (the daemon's resolver, then the home folder).
///
/// A workspace that has terminals nobody focused yet (a restored launch) keeps them: step 3 never
/// brings another workspace's project into it. Another window is never a source.
struct WorkContextTrail: Equatable {
    /// What a trail entry was.
    enum Kind: Hashable, Sendable {
        case terminal
        case chat
    }

    /// One focused terminal or chat tab.
    struct Entry: Equatable, Sendable {
        var tab: String
        var workspace: String
        var window: String
        var kind: Kind
    }

    /// The entries kept; the oldest goes first.
    static let limit = 64

    /// Newest first, one per tab.
    private(set) var entries: [Entry] = []

    /// `entry`'s tab was focused now.
    mutating func record(_ entry: Entry) {
        if entries.first == entry { return }
        entries.removeAll { $0.tab == entry.tab }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// `tab` closed: it is no source any more.
    mutating func forget(tab: String) {
        entries.removeAll { $0.tab == tab }
    }

    /// The first live value of the rule above. `value` reads an entry's value now (its folder, its
    /// chat settings); nil skips the entry (closed, on another machine, no folder yet).
    func resolve<Value>(current: Entry?, workspace: String?, window: String?, workspaceHasWork: Bool,
                        kinds: Set<Kind> = [.terminal, .chat], value: (Entry) -> Value?) -> Value? {
        if let current, kinds.contains(current.kind), let found = value(current) { return found }
        func first(where matches: (Entry) -> Bool) -> Value? {
            for entry in entries where kinds.contains(entry.kind) && entry.tab != current?.tab && matches(entry) {
                if let found = value(entry) { return found }
            }
            return nil
        }
        if let workspace, let found = first(where: { $0.workspace == workspace }) { return found }
        guard !workspaceHasWork, let window else { return nil }
        return first { $0.window == window }
    }
}
