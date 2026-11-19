import CmuxNextDesign
import Foundation

/// The nested sessions under one workspace row (`sidebar.nestedSessions`), as the Rust tree
/// (`sidebar_session_tree`, cmux-layout-reducer) draws them: the workspace's chevron and status
/// mark, and its sub-session rows in order with their depth below the workspace.
nonisolated struct SidebarNestedRows: Hashable, Sendable {
    nonisolated struct Child: Hashable, Sendable {
        var session: SidebarSubSession
        /// 1 for one the workspace's chat started.
        var depth: Int
        var fold: SidebarTreeFold?
        var mark: StatusIndicatorState
    }

    var fold: SidebarTreeFold?
    /// The workspace's status mark when its fold hides a more urgent sub-session; nil keeps its own.
    var mark: StatusIndicatorState?
    var children: [Child] = []
}

nonisolated extension SidebarLayout {
    /// A workspace row's nested sessions: `content` takes their chevron (when the session tree gives the row none)
    /// and a folded parent's rolled-up status mark; the rows to draw under it come back. A row whose session-tree
    /// chevron is folded draws none of them; an open one draws them open (one chevron for both).
    static func nesting(_ ws: WorkspaceID, content: inout WorkspaceRowContent, options o: SidebarLayoutOptions,
                        filtering: Bool) -> SidebarNestedRows? {
        guard o.nestedSessions?.sessions[ws]?.isEmpty == false else { return nil }
        let treeFold = content.treeFold
        if treeFold == .collapsed { return nil }
        guard let nested = nestedRows(ws, activity: content.activity, nested: o.nestedSessions, filtering: filtering,
                                      open: treeFold == .expanded) else { return nil }
        if treeFold == nil {
            content.treeFold = nested.fold
            if let mark = nested.mark { content.activity = mark }
        }
        return nested
    }

    /// Appends the sub-session rows `nested` draws under workspace `ws`'s row (at `depth`): one line each, the
    /// height of a one-line workspace row, so nothing above moves and each row keeps its height.
    static func appendNested(_ nested: SidebarNestedRows?, workspace ws: WorkspaceID, depth: Int, section: SectionID,
                             group: GroupID?, siblingIndex: Int, parentIndex: Int?, color: GroupColor?,
                             metrics m: SidebarLayoutMetrics, to rows: inout [SidebarRow], y: inout CGFloat) {
        guard let nested else { return }
        for child in nested.children {
            var content = WorkspaceRowContent()
            content.treeDepth = depth + child.depth
            content.treeFold = child.fold
            content.activity = child.mark
            let h = m.height(for: WorkspaceRowContent())
            rows.append(SidebarRow(
                key: .subSession(ws, child.session.id), y: y, height: h, section: section,
                group: group, siblingIndex: siblingIndex, parentIndex: parentIndex, isLastInGroup: false,
                isCollapsed: child.fold == .collapsed, childCount: 0, groupColor: color, content: content
            ))
            y += h + m.rowSpacing
        }
    }

    /// The nested rows under `ws`, or nil when it has no sub-sessions (or the tree is off). One Rust
    /// call per workspace that has sub-sessions; none for the rest. `open` draws the workspace's own fold open.
    static func nestedRows(_ ws: WorkspaceID, activity: StatusIndicatorState, nested: SidebarNestedSessionsState?,
                           filtering: Bool, open: Bool = false) -> SidebarNestedRows? {
        guard let nested, let subs = nested.sessions[ws], !subs.isEmpty else { return nil }
        let root = SidebarNestedSessionsState.rowID(ws)
        var rows = [RustNestedRow(id: root, parent: nil, state: RustNestedState(activity))]
        for sub in subs {
            rows.append(RustNestedRow(id: SidebarNestedSessionsState.rowID(ws, sub.id),
                                      parent: sub.parentID.map { SidebarNestedSessionsState.rowID(ws, $0) } ?? root,
                                      state: RustNestedState(sub.state)))
        }
        var expanded = nested.expanded
        var collapsed = nested.collapsed
        if open {
            expanded.insert(root)
            collapsed.remove(root)
        }
        let request = RustNestedTreeRequest(rows: rows, expanded: expanded.sorted(), collapsed: collapsed.sorted(),
                                            expandedByDefault: nested.expandedByDefault, filtering: filtering)
        guard let answer = RustSidebarClient.call("sidebar_session_tree", request, as: RustNestedTreeResponse.self),
              let first = answer.rows.first, first.index == 0 else { return nil }
        var drawn = SidebarNestedRows(fold: first.fold?.fold)
        if first.fold == .collapsed, first.mark != RustNestedState(activity) { drawn.mark = first.mark.indicator }
        for row in answer.rows.dropFirst() {
            // Every sub-session hangs under the workspace (a missing parent falls back to it), so each drawn row
            // past the first is one of them.
            guard row.index >= 1, row.index <= subs.count, row.depth >= 1 else { continue }
            drawn.children.append(.init(session: subs[row.index - 1], depth: row.depth, fold: row.fold?.fold, mark: row.mark.indicator))
        }
        return drawn
    }
}

nonisolated enum RustNestedState: String, Codable {
    case idle, done, running, failed, needsInput

    init(_ activity: StatusIndicatorState) {
        switch activity {
        case .working, .busy: self = .running
        case .waiting: self = .needsInput
        case .error: self = .failed
        case .success: self = .done
        case .idle, .paused: self = .idle
        }
    }

    init(_ state: SidebarSubSession.State) {
        switch state {
        case .running: self = .running
        case .done: self = .done
        case .failed: self = .failed
        case .idle: self = .idle
        }
    }

    var indicator: StatusIndicatorState {
        switch self {
        case .running: .working
        case .needsInput: .waiting
        case .failed: .error
        case .done, .idle: .idle
        }
    }
}

nonisolated enum RustNestedFold: String, Codable {
    case expanded, collapsed

    var fold: SidebarTreeFold { self == .expanded ? .expanded : .collapsed }
}

nonisolated struct RustNestedRow: Encodable {
    var id: String
    var parent: String?
    var state: RustNestedState
}

nonisolated struct RustNestedTreeRequest: Encodable {
    var rows: [RustNestedRow]
    var expanded: [String]
    var collapsed: [String]
    var expandedByDefault: Bool
    var filtering: Bool
}

nonisolated struct RustNestedTreeResponse: Decodable {
    nonisolated struct Row: Decodable {
        var index: Int
        var depth: Int
        var fold: RustNestedFold?
        var mark: RustNestedState
    }

    var rows: [Row]
}
