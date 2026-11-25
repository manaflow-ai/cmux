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
///
/// The trail and the rule are `cmux-focus-core`'s `work_context` (`focus_work_context`): this value
/// mirrors the trail, Rust answers the entries in the rule's order, and ``resolve`` reads them live.
public struct WorkContextTrail: Equatable, Sendable {
    /// What a trail entry was.
    public enum Kind: String, Hashable, Codable, CaseIterable, Sendable {
        /// A terminal tab.
        case terminal
        /// An agent chat tab.
        case chat
    }

    /// One focused terminal or chat tab.
    public struct Entry: Equatable, Codable, Sendable {
        /// The tab's id.
        public var tab: String
        /// The id of the workspace that holds the tab.
        public var workspace: String
        /// The id of the window that showed it.
        public var window: String
        /// Whether it is a terminal or a chat.
        public var kind: Kind

        /// An entry for `tab` of `workspace`, focused in `window`.
        /// - Parameters:
        ///   - tab: The tab's id.
        ///   - workspace: The id of the workspace that holds the tab.
        ///   - window: The id of the window that showed it.
        ///   - kind: Whether it is a terminal or a chat.
        public init(tab: String, workspace: String, window: String, kind: Kind) {
            self.tab = tab
            self.workspace = workspace
            self.window = window
            self.kind = kind
        }
    }

    /// The entries kept; the oldest goes first.
    public static let limit = 64

    /// Newest first, one per tab.
    public private(set) var entries: [Entry] = []

    /// An empty trail.
    public init() {}

    /// `entry`'s tab was focused now.
    /// - Parameter entry: The tab focused now.
    public mutating func record(_ entry: Entry) {
        // A settled focus that changes nothing asks nothing.
        if entries.first == entry { return }
        apply(.record(entry: entry))
    }

    /// `tab` closed: it is no source any more.
    /// - Parameter tab: The id of the closed tab.
    public mutating func forget(tab: String) {
        guard entries.contains(where: { $0.tab == tab }) else { return }
        apply(.forget(tab: tab))
    }

    /// The first live value of the rule above. `value` reads an entry's value now (its folder, its
    /// chat settings); nil skips the entry (closed, on another machine, no folder yet).
    /// - Parameters:
    ///   - current: The tab the person is in, if any.
    ///   - workspace: The target workspace's id.
    ///   - window: The target window's id.
    ///   - workspaceHasWork: Whether the target workspace holds a terminal or chat of its own.
    ///   - kinds: The kinds of entry that may be a source.
    ///   - value: Reads an entry's value now; nil skips the entry.
    /// - Returns: The first live value, or nil when no entry gives one.
    public func resolve<Value>(current: Entry?, workspace: String?, window: String?, workspaceHasWork: Bool,
                        kinds: Set<Kind> = [.terminal, .chat], value: (Entry) -> Value?) -> Value? {
        let target = Target(current: current, workspace: workspace, window: window, workspaceHasWork: workspaceHasWork,
                            kinds: Kind.allCases.filter(kinds.contains))
        let response = FocusReducer.call("focus_work_context", Request(trail: entries, op: .candidates(target: target)),
                                         as: Response.self)
        assert(response?.candidates != nil, "focus_work_context refused")
        for entry in response?.candidates ?? [] {
            if let found = value(entry) { return found }
        }
        return nil
    }

    private struct Target: Encodable {
        var current: Entry?
        var workspace: String?
        var window: String?
        var workspaceHasWork: Bool
        var kinds: [Kind]
    }

    private enum Op: Encodable {
        case record(entry: Entry)
        case forget(tab: String)
        case candidates(target: Target)
    }

    private struct Request: Encodable {
        var trail: [Entry]
        var op: Op
    }

    private struct Response: Decodable {
        var trail: [Entry]?
        var candidates: [Entry]?
    }

    private mutating func apply(_ op: Op) {
        guard let trail = FocusReducer.call("focus_work_context", Request(trail: entries, op: op), as: Response.self)?.trail else {
            assertionFailure("focus_work_context refused")
            return
        }
        entries = trail
    }
}
