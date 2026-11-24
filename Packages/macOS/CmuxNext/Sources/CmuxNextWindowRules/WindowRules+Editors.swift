/// The code editors Open in Editor knows and which one opens a folder (cmux-window-rules `editors`).
/// The App only asks the system which bundle ids resolve; the table, its order and the pick are Rust's.
extension WindowRules {
    /// One editor of the table: its id (`vscode`), name, bundle ids in preference order, menu symbol,
    /// and the URL scheme of its Remote-SSH open when it has one.
    public nonisolated struct Editor: Decodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var bundleIds: [String]
        public var symbol: String
        public var remoteScheme: String?

        public init(id: String, name: String, bundleIds: [String], symbol: String, remoteScheme: String? = nil) {
            (self.id, self.name, self.bundleIds, self.symbol, self.remoteScheme) = (id, name, bundleIds, symbol, remoteScheme)
        }
    }

    /// Which editor opens a folder: `default`, then every installed one in table order, default first.
    public nonisolated struct EditorPick: Decodable, Equatable, Sendable {
        public var `default`: String?
        public var ordered: [String]

        public init(default: String?, ordered: [String]) {
            self.default = `default`
            self.ordered = ordered
        }
    }

    /// The editor table (`window_editors_table`); nil when the FFI does not answer.
    public func editorsTable() -> [Editor]? {
        struct Request: Encodable {}
        struct Reply: Decodable { var editors: [Editor] }
        return call("window_editors_table", Request(), as: Reply.self)?.editors
    }

    /// The pick among `installed` editor ids, with the person's `editor.default` (`configured`).
    public func pickEditor(installed: [String], configured: String?) -> EditorPick? {
        struct Request: Encodable {
            var installed: [String], configured: String?
            enum CodingKeys: String, CodingKey { case installed, configured }
            // `configured` goes as null when unset, as the op's request names it.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(installed, forKey: .installed)
                try container.encode(configured, forKey: .configured)
            }
        }
        return call("window_editors_pick", Request(installed: installed, configured: configured), as: EditorPick.self)
    }
}
