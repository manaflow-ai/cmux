import Foundation

/// The `sidebar_doc_target` reducer op (`cmux-layout-reducer/src/sidebar_doc_target.rs`): where a drop or keyboard
/// move lands in the document, and how an intent naming a remote machine's group reaches the daemon. Each request
/// is one call per pass (a drop, a key press, an intent), never one per row.
nonisolated enum RustSidebarDocTarget {
    static let op = "sidebar_doc_target"

    /// `{op: "target", ...}`: the anchor of `index` among `siblings`; with `nested`, moved off a nested group.
    struct TargetRequest: Encodable {
        let op = "target"
        var section: String
        var parent: String?
        var index: Int
        var siblings: [String]
        var moving: [String]
        var nested: [String]?
    }

    struct TargetReply: Decodable { var target: SidebarDocTarget }
    struct OptionalTargetReply: Decodable { var target: SidebarDocTarget? }

    /// `{op: "unplaced_target", ...}`.
    struct UnplacedRequest: Encodable {
        struct Row: Encodable { var placed: Bool; var session: String? }
        let op = "unplaced_target"
        var in_group: Bool
        var index: Int
        var rows: [Row]
    }

    /// `{op: "keyboard_move", ...}`.
    struct KeyboardMoveRequest: Encodable {
        struct Visible: Encodable { var id: String; var section: String?; var item: String?; var group: String? }
        let op = "keyboard_move"
        var visible: [Visible]
        var moving: [String]
        var items: [String?]
        var up: Bool

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(op, forKey: .op)
            try c.encode(visible, forKey: .visible)
            try c.encode(moving, forKey: .moving)
            // Each moving row's item or JSON null (`Vec<Option<String>>`), never left out.
            var list = c.nestedUnkeyedContainer(forKey: .items)
            for item in items { if let item { try list.encode(item) } else { try list.encodeNil() } }
            try c.encode(up, forKey: .up)
        }

        enum CodingKeys: String, CodingKey { case op, visible, moving, items, up }
    }

    struct KeyboardMoveReply: Decodable {
        struct Move: Decodable { var items: [String]; var target: SidebarDocTarget }
        var move: Move?
    }

    /// `{"machine": ID}`, a machine list section as the op writes one; `null` for any other section.
    struct MachineSection: Codable { var machine: String }

    /// The op's `Intent` (tagged `kind`).
    struct Intent: Codable {
        struct Position: Codable {
            /// Sent as JSON null: the op passes it through and Swift keeps the intent's own section.
            var section: MachineSection?
            var group: String?
            var index: Int

            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let section { try c.encode(section, forKey: .section) } else { try c.encodeNil(forKey: .section) }
                try c.encodeIfPresent(group, forKey: .group)
                try c.encode(index, forKey: .index)
            }

            enum CodingKeys: String, CodingKey { case section, group, index }
        }

        var kind: String
        var group: String?
        var section: MachineSection?
        var machine: String?
        var ids: [String]?
        var to: Position?
    }

    struct ResolvingRequest: Encodable {
        let op = "resolving_host_group"
        var intent: Intent
        var ends: [String: Int]
    }

    struct ResolvingReply: Decodable { var intent: Intent? }

    /// `{op: "document_node_count", ...}`; a node is `"row"` or `{"group": {host, parent?, members}}`.
    struct NodeCountRequest: Encodable {
        enum Node: Encodable {
            case row
            case group(host: Bool, parent: String?, members: Int)

            func encode(to encoder: any Encoder) throws {
                switch self {
                case .row:
                    var c = encoder.singleValueContainer()
                    try c.encode("row")
                case let .group(host, parent, members):
                    var c = encoder.container(keyedBy: Keys.self)
                    var body = c.nestedContainer(keyedBy: Keys.self, forKey: .group)
                    try body.encode(host, forKey: .host)
                    try body.encodeIfPresent(parent, forKey: .parent)
                    try body.encode(members, forKey: .members)
                }
            }

            enum Keys: String, CodingKey { case group, host, parent, members }
        }

        let op = "document_node_count"
        var draws_as_group: Bool
        var nodes: [Node]
    }

    struct NodeCountReply: Decodable { var count: Int }
}

extension SidebarDocTarget: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(section: try c.decode(String.self, forKey: .section), parent: try c.decodeIfPresent(String.self, forKey: .parent),
                  before: try c.decodeIfPresent(String.self, forKey: .before), after: try c.decodeIfPresent(String.self, forKey: .after),
                  index: try c.decodeIfPresent(Int.self, forKey: .index))
    }
}
