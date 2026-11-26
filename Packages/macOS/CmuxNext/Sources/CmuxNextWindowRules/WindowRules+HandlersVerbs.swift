public import Foundation

/// The verb handlers' small rules (cmux-window-rules `handlers_verbs`, ops `handlers_verbs_*`): a remote
/// port argument and port list, Switch Host's pick, Open as Pane's folder, a workspace's PR links,
/// Duplicate Tab's plan, a tab move that becomes a split, and a group walk and its ungroup index.
extension WindowRules {
    /// A `--port` argument as the invocation holds it: an integer or text.
    public nonisolated enum PortValue: Encodable, Sendable {
        case int(Int), text(String)

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            }
        }
    }

    /// `--port N`, 1 to 65535 (text trimmed of spaces and tabs); nil: no port.
    public func portArgument(_ value: PortValue?) -> Int? {
        guard let value else { return nil }
        struct Request: Encodable { var port: PortValue }
        struct Reply: Decodable { var port: Int? }
        return call("handlers_verbs_port_argument", Request(port: value), as: Reply.self)?.port
    }

    /// One forwarded port of a machine's link.
    public nonisolated struct Forward: Encodable, Sendable {
        public var port: Int
        public var url: String

        public init(port: Int, url: String) {
            self.port = port
            self.url = url
        }
    }

    /// List Forwarded Ports' text, one `port → url` line each; nil for no forward.
    public func portListText(_ forwards: [Forward]) -> String? {
        struct Request: Encodable { var forwards: [Forward] }
        struct Reply: Decodable { var text: String? }
        return call("handlers_verbs_port_list_text", Request(forwards: forwards), as: Reply.self)?.text
    }

    /// One row of the Hosts section.
    public nonisolated struct HostRow: Encodable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Switch Host…'s pick: the host the run names (a machine target, else the `machine` argument as a
    /// target, else as text) and its row (by id, else by name); nil when the FFI does not answer.
    public func switchHost(target: TargetRef?, machineTarget: String?, machineText: String?, rows: [HostRow]) -> (wanted: String?, row: Int?)? {
        struct Request: Encodable { var target: TargetRef?, machineTarget: String?, machineText: String?, rows: [HostRow] }
        struct Reply: Decodable { var wanted: String?, row: Int? }
        let request = Request(target: target, machineTarget: machineTarget, machineText: machineText, rows: rows)
        return call("handlers_verbs_switch_host", request, as: Reply.self).map { ($0.wanted, $0.row) }
    }

    /// The folder Open Files as Pane opens on: `path` (trimmed, `~` expanded, a relative one under
    /// `paneFolder`, else `home`), else `paneFolder`. nil means home.
    public func paneFolder(path: String?, paneFolder: String?, home: String) -> String? {
        struct Request: Encodable { var path: String?, paneFolder: String?, home: String }
        struct Reply: Decodable { var folder: String? }
        return call("handlers_verbs_pane_folder", Request(path: path, paneFolder: paneFolder, home: home), as: Reply.self)?.folder
    }

    /// One status entry of a workspace and the links found in its text.
    public nonisolated struct StatusLinks: Encodable, Sendable {
        public var key: String
        public var links: [String]

        public init(key: String, links: [String]) {
            self.key = key
            self.links = links
        }
    }

    /// Open All Workspace PR Links: the `prKey` entry's links first, then the others', each once, http and https only.
    public func prLinks(_ entries: [StatusLinks], prKey: String) -> [String] {
        struct Request: Encodable { var entries: [StatusLinks], prKey: String }
        struct Reply: Decodable { var links: [String] }
        return call("handlers_verbs_pr_links", Request(entries: entries, prKey: prKey), as: Reply.self)?.links ?? []
    }

    /// One tab Duplicate Tab acts on, and whether it is another Mac's chat.
    public nonisolated struct DuplicateTab: Encodable, Sendable {
        public var facts: DuplicateFacts
        public var otherHost: Bool

        public init(_ facts: DuplicateFacts, otherHost: Bool) {
            self.facts = facts
            self.otherHost = otherHost
        }

        private enum Key: String, CodingKey { case otherHost }

        public func encode(to encoder: any Encoder) throws {
            try facts.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(otherHost, forKey: .otherHost)
        }
    }

    /// Why Duplicate Tab duplicates nothing.
    public nonisolated enum DuplicateRefusal: String, Decodable, Sendable {
        case agentTabOtherHost, pageTabOpensOnce
    }

    /// Duplicate Tab's plan: one action per tab (`browser`, `localBrowser`, `agent`, `skip`, `terminal`,
    /// `elsewhere`), else why none; nil when the FFI does not answer.
    public func duplicatePlan(_ tabs: [DuplicateTab]) -> (actions: [String], refusal: DuplicateRefusal?)? {
        struct Request: Encodable { var tabs: [DuplicateTab] }
        struct Reply: Decodable { var actions: [String], refusal: DuplicateRefusal? }
        return call("handlers_verbs_duplicate_plan", Request(tabs: tabs), as: Reply.self).map { ($0.actions, $0.refusal) }
    }

    /// The split a Move Tab to Pane Left/Right/Up/Down makes at the screen's edge; nil for none.
    public func moveSplit(_ action: String, tabsInPane: Int) -> String? {
        struct Request: Encodable { var action: String, tabsInPane: Int }
        struct Reply: Decodable { var direction: String? }
        return call("handlers_verbs_move_split", Request(action: action, tabsInPane: tabsInPane), as: Reply.self)?.direction
    }

    /// The order Next/Previous Workspace Group tries `count` groups in, from `active`, wrapping.
    public func groupWalk(count: Int, active: Int?, offset: Int) -> [Int] {
        struct Request: Encodable { var count: Int, active: Int?, offset: Int }
        struct Reply: Decodable { var order: [Int] }
        return call("handlers_verbs_group_walk", Request(count: count, active: active, offset: offset), as: Reply.self)?.order ?? []
    }

    /// Where Remove from Group puts a section's ungrouped workspaces; nil when the FFI does not answer.
    public func ungroupIndex(ungroupedFirst: Bool, firstUnpinnedGroup: Int?, nodeCount: Int, groupNode: Int) -> Int? {
        struct Request: Encodable { var ungroupedFirst: Bool, firstUnpinnedGroup: Int?, nodeCount: Int, groupNode: Int }
        return call("handlers_verbs_ungroup_index",
                    Request(ungroupedFirst: ungroupedFirst, firstUnpinnedGroup: firstUnpinnedGroup, nodeCount: nodeCount, groupNode: groupNode),
                    as: Index.self)?.index
    }
}
