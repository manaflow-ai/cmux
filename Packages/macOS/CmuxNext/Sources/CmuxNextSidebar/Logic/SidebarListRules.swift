// The wire shapes of Rust `sidebar_list_rules` (an op of `cmux_layout_reducer_json`, through `RustSidebarClient`).

nonisolated struct ListEntry: Codable { var index: Int, depth: Int }
nonisolated struct ListGap: Encodable { var section: String, group: String?, index: Int }
nonisolated struct ListMatchGroup: Encodable { var id: String, parent: String?, visible: Bool }
nonisolated struct ListRule: Encodable {
    var rule: String, drawn: [ListEntry]?, workspaces: [ListWorkspace?]?, limits: [Bool]?, options: ListOptions?
    var dragged: [ListWorkspace]?, gap: ListGap?, section: String?, group: String?, count: Int?, groups: [ListMatchGroup]?

    init(rule: String, drawn: [ListEntry]? = nil, workspaces: [ListWorkspace?]? = nil, limits: [Bool]? = nil,
         options: ListOptions? = nil, dragged: [ListWorkspace]? = nil, gap: ListGap? = nil, section: String? = nil,
         group: String? = nil, count: Int? = nil, groups: [ListMatchGroup]? = nil) {
        (self.rule, self.drawn, self.workspaces, self.limits, self.options) = (rule, drawn, workspaces, limits, options)
        (self.dragged, self.gap, self.section, self.group, self.count, self.groups) = (dragged, gap, section, group, count, groups)
    }
}
/// Every rule's answer: the fields of the one asked.
nonisolated struct ListReply: Decodable { var drawn: [ListEntry]?, unfolds: Bool?, entry: Int?, atEnd: Bool?, path: [String]? }

nonisolated struct ListWorkspace: Encodable {
    var id: String, done: Bool, archived: Bool, needsYou: Bool
    init(_ w: SidebarWorkspace) { (id, done, archived, needsYou) = (w.id.rawValue, w.taskStatus == .done, w.isArchived, w.agentChip == .needsYou) }
}

/// `SidebarLayoutOptions` for one list's folds (`list`); `parents`: send the session tree's lineage (`dragUnfolds`).
nonisolated struct ListOptions: Encodable {
    nonisolated struct Tree: Encodable { var parents: [String: String], hidesStarted: Bool }
    var active: String?, filtering: Bool, foldsDone: Bool, foldsArchived: Bool, archiveSection: Bool, settled: [String]
    var tree: Tree?, rowLimit: Int, open: [String], showMoreOpen: Bool

    init(_ o: SidebarLayoutOptions, list: SidebarDoneFoldID?, parents: Bool = false) {
        (active, filtering, rowLimit) = (o.activeWorkspaceID?.rawValue, o.filterMatches != nil, o.rowLimit)
        (foldsDone, foldsArchived, archiveSection) = (o.foldsDone, o.foldsArchived, o.archiveSection)
        settled = o.settled.map(\.rawValue).sorted()
        tree = o.sessionTree.map { t in
            Tree(parents: parents ? .init(uniqueKeysWithValues: t.parents.map { ($0.key.rawValue, $0.value.rawValue) }) : [:], hidesStarted: t.hidesStarted)
        }
        let kinds: [(SidebarDoneFoldID.Kind, String)] = [(.done, "done"), (.settled, "settled"), (.archived, "archived")]
        open = list.map { id in kinds.compactMap { o.openDoneFolds.contains(id.of($0.0)) ? $0.1 : nil } } ?? []
        showMoreOpen = list.map(o.openShowMore.contains) ?? false
    }
}
