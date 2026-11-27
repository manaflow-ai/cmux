/// How an action finds what it acts on (cmux-window-rules `targets`): the one "9 is the last"
/// ordinal pick, the one wrapping step, the one "id, then folded name" lookup, the explicit target,
/// a tab group action's tab list, and the refusal a handler's failure becomes.
extension WindowRules {
    /// What a number past the end of the list picks.
    public nonisolated enum PastEnd: String, Encodable, Sendable {
        /// The last one (tabs, spaces).
        case clamp
        /// Nothing (screens); 9 is still the last.
        case refuse
    }

    /// One candidate of a named lookup: its id and its name folded by the app (case, diacritics).
    public nonisolated struct Named: Encodable, Equatable, Sendable {
        public var id: String
        public var folded: String

        public init(id: String, folded: String) {
            self.id = id
            self.folded = folded
        }
    }

    /// An object an invocation names, as the explicit target rule reads it.
    public nonisolated struct TargetRef: Encodable, Equatable, Sendable {
        public var kind: String
        public var id: String

        public init(kind: String, id: String) {
            self.kind = kind
            self.id = id
        }
    }

    /// How a refusal reaches the person and the caller.
    public nonisolated enum Refusal: String, Decodable, Sendable {
        case notFound, quiet, shown
    }

    /// A rule the FFI did not answer (a pinned FFI without the op), for a handler that refuses then.
    public nonisolated struct Unanswered: Error, CustomStringConvertible, Sendable {
        public var operation: String
        public var description: String { "window rule \(operation) did not answer" }

        public init(operation: String) { self.operation = operation }
    }

    /// An answer naming one index, nil for none.
    struct Index: Decodable { var index: Int? }

    /// The index `number` (1-based; 9 is the last) picks among `count`; nil picks nothing.
    public func ordinal(_ number: Int, count: Int, pastEnd: PastEnd) -> Int? {
        struct Request: Encodable { var number: Int, count: Int, pastEnd: PastEnd }
        return call("window_target_ordinal", Request(number: number, count: count, pastEnd: pastEnd), as: Index.self)?.index
    }

    /// The index `offset` steps from `index` among `count`, wrapping around; nil for an empty list.
    public func step(_ index: Int, by offset: Int, count: Int) -> Int? {
        struct Request: Encodable { var index: Int, offset: Int, count: Int }
        return call("window_target_step", Request(index: index, offset: offset, count: count), as: Index.self)?.index
    }

    /// The candidate `text` names: by id, else by `folded` name; nil when none does.
    public func named(_ text: String, folded: String, among candidates: [Named]) -> Int? {
        struct Request: Encodable { var text: String, folded: String, candidates: [Named] }
        return call("window_target_named", Request(text: text, folded: folded, candidates: candidates), as: Index.self)?.index
    }

    /// The first of `candidates` (target, then arguments; nil where absent) of one of `kinds`.
    public func explicitTarget(_ candidates: [TargetRef?], kinds: [String]) -> Int? {
        struct Request: Encodable { var candidates: [TargetRef?], kinds: [String] }
        return call("window_target_explicit", Request(candidates: candidates, kinds: kinds), as: Index.self)?.index
    }

    /// The tab ids a `tabs` argument names (comma-separated, trimmed, no empty entry).
    public func tabIDs(_ list: String) -> [String] {
        struct Request: Encodable { var list: String }
        struct Reply: Decodable { var ids: [String] }
        return call("window_target_tab_ids", Request(list: list), as: Reply.self)?.ids ?? []
    }

    /// Why tabs found in `panes` cannot act together (`noTab`, `tabsInDifferentPanes`); nil: they can.
    public func onePaneRefusal(_ panes: [String]) -> String? {
        struct Request: Encodable { var panes: [String] }
        struct Reply: Decodable { var refusal: String? }
        return call("window_target_one_pane", Request(panes: panes), as: Reply.self)?.refusal
    }

    /// The refusal a thrown failure becomes (not found first, then quiet); shown when the FFI does not answer.
    public func refusal(notFound: Bool, quiet: Bool) -> Refusal {
        struct Request: Encodable { var notFound: Bool, quiet: Bool }
        struct Reply: Decodable { var refusal: Refusal }
        return call("window_target_refusal", Request(notFound: notFound, quiet: quiet), as: Reply.self)?.refusal ?? .shown
    }
}
