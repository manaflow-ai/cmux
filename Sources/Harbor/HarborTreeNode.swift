import Foundation

/// One row of the Harbor outline, built from the discovered host snapshots: a
/// host (this Mac or an SSH destination), a tool session on it, a
/// window/workspace group inside a session, an attachable terminal, or a
/// one-line placeholder (unreachable reason, empty host, scanning).
///
/// Reference type so `NSOutlineView` can use the node as its item; identity is
/// the stable `id` (host key, session path, terminal path), which lets
/// expansion and selection survive a rebuild.
final class HarborTreeNode: NSObject {
    enum Kind: Equatable {
        /// A discovery source: this Mac or a user-added SSH host.
        case host(HarborHostRef, status: HarborHostSnapshot.Status)
        /// A tool session on a host (tmux/zellij/screen/zmx/herdr/cmux-tui).
        case session(host: HarborHostRef, info: HarborSessionInfo)
        /// A window/workspace group inside a session.
        case windowGroup(label: String)
        /// One inner terminal; draggable only when it exposes a direct-attach leaf.
        case terminal(host: HarborHostRef, tool: HarborTool, info: HarborTerminalInfo)
        /// A single explanatory line (unreachable reason, empty, scanning).
        case placeholder(text: String)
    }

    let id: String
    private(set) var kind: Kind
    private(set) var children: [HarborTreeNode]

    init(id: String, kind: Kind, children: [HarborTreeNode] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var isExpandable: Bool { !children.isEmpty }

    var isHostRow: Bool {
        if case .host = kind { return true }
        return false
    }

    /// The host key a host row persists its collapse under; nil elsewhere.
    var hostKey: String? {
        if case .host(let host, _) = kind { return host.key }
        return nil
    }

    /// The case of `kind` without its payload: what decides row height, menus,
    /// expandability and drag-ability. Two trees with equal structure signatures
    /// can be updated in place; a content-only change never needs `reloadData`.
    var structureTag: String {
        switch kind {
        case .host: return "host"
        case .session: return "session"
        case .windowGroup: return "windowGroup"
        case .terminal: return "terminal"
        case .placeholder: return "placeholder"
        }
    }

    /// Copies the values of an equal-structure rebuild into this node
    /// (NSOutlineView keeps the object it was handed; updating it in place
    /// keeps rows, expansion and the selection untouched). Children are adopted
    /// pairwise — callers guarantee the structure signature matched first.
    func adopt(from other: HarborTreeNode) {
        kind = other.kind
        for (child, replacement) in zip(children, other.children) {
            child.adopt(from: replacement)
        }
    }

    /// The text a quick-search (`/`) matches against.
    var searchableTitle: String {
        switch kind {
        case .host(let host, _): return host.displayName
        case .session(_, let info): return info.name
        case .windowGroup(let label): return label
        case .terminal(_, _, let info):
            var parts = [info.agent?.displayName, info.title.isEmpty ? info.shortID : info.title]
            if let cwd = info.cwd, !cwd.isEmpty { parts.append(cwd) }
            if let message = info.agent?.message, !message.isEmpty { parts.append(message) }
            return parts.compactMap { $0 }.joined(separator: " ")
        case .placeholder(let text): return text
        }
    }

    /// What dragging (or clicking) this row means: a direct API attach of one
    /// inner terminal, or a whole-session TUI attach for zmx (whose client is
    /// one chromeless terminal). Hosts, groups, view-only terminals and
    /// placeholders only organize and are not draggable.
    var dragItem: HarborDragItem? {
        switch kind {
        case .terminal(_, _, let info):
            guard let leaf = info.leaf else { return nil }
            return .leaf(leaf, title: info.title.isEmpty ? info.shortID : info.title)
        case .session(let host, let info):
            guard info.tool == .zmx else { return nil }
            return .sessionTUI(host: host, tool: info.tool, sessionName: info.name, state: info.state)
        case .host, .windowGroup, .placeholder:
            return nil
        }
    }

    // NSOutlineView keys items by object identity; equality by id keeps
    // `item(atRow:)` lookups stable across snapshot rebuilds.
    override func isEqual(_ object: Any?) -> Bool {
        (object as? HarborTreeNode)?.id == id
    }

    override var hash: Int { id.hashValue }
}

/// Pure assembly of outline nodes from the discovered host snapshots. Node ids
/// are stable across rebuilds (host key, then tool/session name, then window
/// id, then terminal short id) so expansion and selection survive a refresh.
enum HarborTreeNodeBuilder {
    static func nodes(from snapshots: [HarborHostSnapshot]) -> [HarborTreeNode] {
        snapshots.map { snapshot in
            HarborTreeNode(
                id: nodeID(host: snapshot.host),
                kind: .host(snapshot.host, status: snapshot.status),
                children: hostChildren(snapshot)
            )
        }
    }

    static func nodeID(host: HarborHostRef) -> String { host.key }
    static func nodeID(host: HarborHostRef, session: HarborSessionInfo) -> String {
        "\(host.key)/\(session.tool.rawValue)/\(session.name)"
    }
    static func nodeID(session sessionID: String, window: HarborWindowInfo) -> String {
        "\(sessionID)/w/\(window.id)"
    }
    static func nodeID(parent parentID: String, terminal: HarborTerminalInfo) -> String {
        // `shortID` is display text and can collide after truncation. Keep the
        // full probe identity in the outline key so two daemon terminals can
        // never adopt one another's row during a refresh.
        "\(parentID)/t/\(terminal.stableID)"
    }
    static func nodeID(placeholder host: HarborHostRef) -> String { "\(host.key)/placeholder" }

    private static func hostChildren(_ snapshot: HarborHostSnapshot) -> [HarborTreeNode] {
        var children = snapshot.sessions
            .sorted(by: sessionComesBefore)
            .map { sessionNode(host: snapshot.host, info: $0) }
        switch snapshot.status {
        case .unreachable(let reason):
            children.insert(placeholder(snapshot.host, text: reason), at: 0)
        case .loaded:
            if children.isEmpty {
                children.append(placeholder(
                    snapshot.host,
                    text: String(localized: "harbor.empty", defaultValue: "No sessions found.")
                ))
            }
        case .loading:
            if children.isEmpty {
                children.append(placeholder(
                    snapshot.host,
                    text: String(localized: "harbor.refreshing", defaultValue: "Scanning\u{2026}")
                ))
            }
        }
        return children
    }

    private static func sessionNode(host: HarborHostRef, info: HarborSessionInfo) -> HarborTreeNode {
        let sessionID = nodeID(host: host, session: info)
        var children: [HarborTreeNode] = info.windows.map { window in
            let windowID = nodeID(session: sessionID, window: window)
            return HarborTreeNode(
                id: windowID,
                kind: .windowGroup(label: window.label),
                children: window.terminals
                    .sorted(by: terminalComesBefore)
                    .map {
                    terminalNode(parentID: windowID, host: host, tool: info.tool, info: $0)
                }
            )
        }
        children.append(contentsOf: info.looseTerminals.sorted(by: terminalComesBefore).map {
            terminalNode(parentID: sessionID, host: host, tool: info.tool, info: $0)
        })
        return HarborTreeNode(
            id: sessionID,
            kind: .session(host: host, info: info),
            children: children
        )
    }

    private static func terminalNode(
        parentID: String,
        host: HarborHostRef,
        tool: HarborTool,
        info: HarborTerminalInfo
    ) -> HarborTreeNode {
        HarborTreeNode(
            id: nodeID(parent: parentID, terminal: info),
            kind: .terminal(host: host, tool: tool, info: info)
        )
    }

    private static func sessionComesBefore(_ lhs: HarborSessionInfo, _ rhs: HarborSessionInfo) -> Bool {
        let left = lhs.windows.flatMap(\.terminals) + lhs.looseTerminals
        let right = rhs.windows.flatMap(\.terminals) + rhs.looseTerminals
        let leftRank = left.map(\.attentionRank).min() ?? HarborAgentState.unknown.attentionRank
        let rightRank = right.map(\.attentionRank).min() ?? HarborAgentState.unknown.attentionRank
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.tool != rhs.tool { return lhs.tool.rawValue < rhs.tool.rawValue }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func terminalComesBefore(_ lhs: HarborTerminalInfo, _ rhs: HarborTerminalInfo) -> Bool {
        if lhs.attentionRank != rhs.attentionRank { return lhs.attentionRank < rhs.attentionRank }
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        let left = lhs.agent?.displayName ?? lhs.title
        let right = rhs.agent?.displayName ?? rhs.title
        let comparison = left.localizedStandardCompare(right)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.stableID < rhs.stableID
    }

    private static func placeholder(_ host: HarborHostRef, text: String) -> HarborTreeNode {
        HarborTreeNode(id: nodeID(placeholder: host), kind: .placeholder(text: text))
    }

    /// Depth-first flattening in display order (every node expanded).
    static func flattened(_ nodes: [HarborTreeNode]) -> [HarborTreeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }

    /// Row identities, order and kinds — a change here needs `reloadData`.
    static func structureSignature(_ nodes: [HarborTreeNode]) -> [String] {
        flattened(nodes).map { "\($0.id)|\($0.structureTag)|\($0.children.count)" }
    }

    /// Everything a row displays — a change here with an equal structure
    /// signature is applied to the existing rows in place.
    static func contentSignature(_ nodes: [HarborTreeNode]) -> [String] {
        flattened(nodes).map { "\($0.id)|\(String(describing: $0.kind))" }
    }
}
