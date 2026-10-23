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
    mutating func record(_ entry: Entry) {}

    /// `tab` closed: it is no source any more.
    mutating func forget(tab: String) {}

    /// The first live value of the rule above. `value` reads an entry's value now (its folder, its
    /// chat settings); nil skips the entry (closed, on another machine, no folder yet).
    func resolve<Value>(current: Entry?, workspace: String?, window: String?, workspaceHasWork: Bool,
                        kinds: Set<Kind> = [.terminal, .chat], value: (Entry) -> Value?) -> Value? {
        nil
    }
}
