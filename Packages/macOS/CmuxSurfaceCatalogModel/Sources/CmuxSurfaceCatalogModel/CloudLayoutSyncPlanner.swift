import Foundation

/// Plans the next mutation that converges one daemon workspace to a native split tree.
///
/// The daemon's `workspace.layout.apply` rearranges tree shape, ratios and tab order,
/// but only over the panes and splits the screen already has. Membership changes are
/// therefore planned first, one step at a time, from the snapshot the caller just read:
///
/// 1. A native pane with no machine pane gets one by splitting (a scratch terminal
///    holds the new pane open until a real tab arrives, then is closed).
/// 2. Each tab is moved to its native pane and index with `tab.move`; a machine pane
///    whose last tab leaves is removed by the daemon.
/// 3. With membership equal, the full layout document is applied once.
///
/// Planning never guesses: a tab that exists on only one side is ``CloudLayoutSyncStep/notReady(_:)``,
/// and a shape this client does not write is ``CloudLayoutSyncStep/unsupported(_:)``.
///
/// ```swift
/// let planner = CloudLayoutSyncPlanner(snapshot: snapshot, workspaceID: "ws_1", desired: tree)
/// if case .moveTab(let tabID, let target) = planner.step { /* send tab.move */ }
/// ```
public struct CloudLayoutSyncPlanner: Sendable {
    /// The next step for the snapshot this planner was built from.
    public let step: CloudLayoutSyncStep

    /// Differences below this are treated as equal: native dividers round to pixels.
    static let ratioTolerance = 0.005

    /// Plans from a decoded `session.snapshot` result.
    ///
    /// - Parameters:
    ///   - snapshot: The machine's current snapshot, including screen layout documents.
    ///   - workspaceID: The daemon workspace bound to the native workspace.
    ///   - desired: The native split tree in daemon tab IDs.
    ///   - scratchTabIDs: Tabs this sync started with ``CloudLayoutSyncStep/splitPane(paneID:)``.
    ///     They are not part of the native tree and are closed once their pane is settled.
    public init(snapshot: [String: Any], workspaceID: String, desired: CloudLayoutSyncTree, scratchTabIDs: Set<String> = []) {
        step = Self.plan(snapshot: snapshot, workspaceID: workspaceID, desired: desired, scratchTabIDs: scratchTabIDs)
    }

    // MARK: - Planning

    private static func plan(
        snapshot: [String: Any],
        workspaceID: String,
        desired: CloudLayoutSyncTree,
        scratchTabIDs: Set<String>
    ) -> CloudLayoutSyncStep {
        let screens = ((snapshot["screens"] as? [[String: Any]]) ?? []).filter { $0["workspace_id"] as? String == workspaceID }
        guard !screens.isEmpty else { return .notReady("the workspace has no screen") }
        guard screens.count == 1 else { return .unsupported("the workspace has several screens") }
        guard let screenID = screens[0]["id"] as? String,
              let document = screens[0]["layout"] as? [String: Any],
              let daemon = LayoutNode(daemon: document["root"]) else {
            return .unsupported("the screen layout is not a split tree")
        }
        var terminalByTab: [String: String] = [:]
        for tab in (snapshot["tabs"] as? [[String: Any]]) ?? [] {
            guard let id = tab["id"] as? String, tab["content_kind"] as? String == "terminal",
                  let terminal = tab["content_id"] as? String else { continue }
            terminalByTab[id] = terminal
        }

        let nativeTabs = desired.leaves.flatMap(\.tabIDs)
        guard desired.leaves.allSatisfy({ !$0.tabIDs.isEmpty }), Set(nativeTabs).count == nativeTabs.count else {
            return .unsupported("the native tree has an empty pane or a repeated tab")
        }
        let panes = daemon.leaves
        let daemonTabs = panes.flatMap(\.tabIDs)
        let scratch = scratchTabIDs.intersection(daemonTabs)
        // Membership is owned by creates and closes, not by this writer. A native tab
        // the machine already closed is dropped, and a machine tab this Mac has not
        // projected yet (another client, an agent) stays beside its current neighbor,
        // so the user's arrangement is written without waiting for either to settle.
        guard var target = desired.keeping(Set(daemonTabs).subtracting(scratch)) else {
            return .notReady("no native tab is on the machine")
        }
        var placed = Set(target.leaves.flatMap(\.tabIDs))
        for pane in panes {
            for (index, tabID) in pane.tabIDs.enumerated() where !placed.contains(tabID) && !scratch.contains(tabID) {
                if let anchor = pane.tabIDs[..<index].last(where: placed.contains) {
                    target = target.inserting(tabID, beside: anchor, after: true)
                } else if let anchor = pane.tabIDs[(index + 1)...].first(where: placed.contains) {
                    target = target.inserting(tabID, beside: anchor, after: false)
                } else {
                    return .notReady("a machine pane holds only tabs this Mac has not shown yet")
                }
                placed.insert(tabID)
            }
        }
        let wanted = target.leaves
        func close(_ tabID: String) -> CloudLayoutSyncStep {
            guard let terminal = terminalByTab[tabID] else { return .unsupported("a scratch tab has no terminal") }
            return .closeScratch(tabID: tabID, terminalID: terminal)
        }
        // A scratch terminal is only a placeholder: once a real tab shares its pane, it goes.
        if let tabID = panes.first(where: { $0.tabIDs.count > 1 && $0.tabIDs.contains(where: scratch.contains) })?
            .tabIDs.first(where: scratch.contains) {
            return close(tabID)
        }

        // Keep each machine pane where most of its tabs already are, so a pane's
        // identity (and its scrollback owner) survives the rearrangement.
        var candidates: [(score: Int, leaf: Int, pane: Int)] = []
        for (leafIndex, leaf) in wanted.enumerated() {
            let members = Set(leaf.tabIDs)
            for (paneIndex, pane) in panes.enumerated() {
                let score = pane.tabIDs.filter(members.contains).count
                if score > 0 { candidates.append((score, leafIndex, paneIndex)) }
            }
        }
        candidates.sort { ($0.score, -$0.leaf, -$0.pane) > ($1.score, -$1.leaf, -$1.pane) }
        var paneForLeaf: [Int: String] = [:]
        var usedPanes = Set<String>()
        for candidate in candidates where paneForLeaf[candidate.leaf] == nil {
            let paneID = panes[candidate.pane].paneID
            guard usedPanes.insert(paneID).inserted else { continue }
            paneForLeaf[candidate.leaf] = paneID
        }
        let scratchPanes = panes.filter { $0.tabIDs.allSatisfy(scratch.contains) }.map(\.paneID)
        for leafIndex in wanted.indices where paneForLeaf[leafIndex] == nil {
            guard let paneID = scratchPanes.first(where: { !usedPanes.contains($0) }) else { continue }
            usedPanes.insert(paneID)
            paneForLeaf[leafIndex] = paneID
        }
        if let leafIndex = wanted.indices.first(where: { paneForLeaf[$0] == nil }) {
            let anchor = wanted[leafIndex].tabIDs[0]
            guard let paneID = panes.first(where: { $0.tabIDs.contains(anchor) })?.paneID else {
                return .notReady("a native tab has no machine pane")
            }
            return .splitPane(paneID: paneID)
        }
        if let unused = panes.first(where: { !usedPanes.contains($0.paneID) && $0.tabIDs.allSatisfy(scratch.contains) }),
           let tabID = unused.tabIDs.first {
            return close(tabID)
        }

        for (leafIndex, leaf) in wanted.enumerated() {
            guard let paneID = paneForLeaf[leafIndex],
                  let current = panes.first(where: { $0.paneID == paneID })?.tabIDs.filter({ !scratch.contains($0) }) else {
                continue
            }
            // Earlier indexes already match, so `index` never exceeds the pane's tab count.
            for (index, tabID) in leaf.tabIDs.enumerated() where index >= current.count || current[index] != tabID {
                return .moveTab(tabID: tabID, target: CloudTuiTerminalProjectionTarget(
                    workspaceID: workspaceID, screenID: screenID, paneID: paneID, index: index
                ))
            }
        }

        var leafCursor = 0
        let layoutTree = LayoutNode(desired: target, panes: paneForLeaf, daemonActive: daemon.activeTabs, cursor: &leafCursor)
            .assigningSplitIDs(from: daemon)
        if layoutTree.matches(daemon) { return .done }
        let paneIDs = Set(paneForLeaf.values)
        let active = (document["active_pane_id"] as? String).flatMap { paneIDs.contains($0) ? $0 : nil }
            ?? paneForLeaf[0] ?? ""
        let zoomed = (document["zoomed_pane_id"] as? String).flatMap { paneIDs.contains($0) ? $0 : nil }
        let object: [String: Any] = [
            "version": 1,
            "screen_id": screenID,
            "active_pane_id": active,
            "zoomed_pane_id": zoomed ?? NSNull(),
            "root": layoutTree.json,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .unsupported("the layout document could not be encoded")
        }
        return .applyLayout(data)
    }
}

/// One node of a screen's split tree, shared by the daemon's document and the native target.
private indirect enum LayoutNode {
    case leaf(paneID: String, tabIDs: [String], activeTabID: String?)
    case split(splitID: String?, horizontal: Bool, ratio: Double, first: LayoutNode, second: LayoutNode)

    /// Reads a daemon `LayoutDocument` node. Stacks and viewports are not written by
    /// this client, so they read as nil and the caller leaves the machine untouched.
    init?(daemon raw: Any?) {
        guard let object = raw as? [String: Any] else { return nil }
        switch object["kind"] as? String {
        case "leaf":
            guard let paneID = object["pane_id"] as? String,
                  let tabIDs = object["tab_ids"] as? [String], !tabIDs.isEmpty else { return nil }
            self = .leaf(paneID: paneID, tabIDs: tabIDs, activeTabID: object["active_tab_id"] as? String)
        case "split":
            let horizontal: Bool
            switch object["direction"] as? String {
            case "horizontal", "right": horizontal = true
            case "vertical", "down": horizontal = false
            default: return nil
            }
            guard let splitID = object["split_id"] as? String,
                  let ratio = (object["ratio"] as? NSNumber)?.doubleValue,
                  let first = LayoutNode(daemon: object["first"]),
                  let second = LayoutNode(daemon: object["second"]) else { return nil }
            self = .split(splitID: splitID, horizontal: horizontal, ratio: ratio, first: first, second: second)
        default:
            return nil
        }
    }

    /// The native target with each leaf bound to its planned machine pane.
    init(desired: CloudLayoutSyncTree, panes: [Int: String], daemonActive: [String: String], cursor: inout Int) {
        switch desired {
        case .leaf(let tabIDs, let activeTabID):
            let paneID = panes[cursor] ?? ""
            cursor += 1
            let active = activeTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
                ?? daemonActive[paneID].flatMap { tabIDs.contains($0) ? $0 : nil }
            self = .leaf(paneID: paneID, tabIDs: tabIDs, activeTabID: active)
        case .split(let horizontal, let ratio, let first, let second):
            let first = LayoutNode(desired: first, panes: panes, daemonActive: daemonActive, cursor: &cursor)
            let second = LayoutNode(desired: second, panes: panes, daemonActive: daemonActive, cursor: &cursor)
            self = .split(splitID: nil, horizontal: horizontal, ratio: ratio, first: first, second: second)
        }
    }

    var leaves: [(paneID: String, tabIDs: [String])] {
        switch self {
        case .leaf(let paneID, let tabIDs, _): return [(paneID, tabIDs)]
        case .split(_, _, _, let first, let second): return first.leaves + second.leaves
        }
    }

    var paneIDs: Set<String> { Set(leaves.map(\.paneID)) }

    var activeTabs: [String: String] {
        switch self {
        case .leaf(let paneID, _, let active): return active.map { [paneID: $0] } ?? [:]
        case .split(_, _, _, let first, let second): return first.activeTabs.merging(second.activeTabs) { current, _ in current }
        }
    }

    /// Split IDs keyed by the panes each split encloses, in document order.
    var splits: [(id: String?, panes: Set<String>)] {
        switch self {
        case .leaf: return []
        case .split(let id, _, _, let first, let second):
            return [(id, paneIDs)] + first.splits + second.splits
        }
    }

    /// Reuses a daemon split wherever it encloses the same panes; the rest take the
    /// remaining IDs. The daemon requires the exact set of the screen's split IDs.
    func assigningSplitIDs(from daemon: LayoutNode) -> LayoutNode {
        let daemonSplits = daemon.splits
        let exact = Dictionary(daemonSplits.compactMap { split in split.id.map { (split.panes, $0) } }) { first, _ in first }
        let reused = Set(splits.compactMap { exact[$0.panes] })
        var remaining = daemonSplits.compactMap(\.id).filter { !reused.contains($0) }
        return withSplitIDs(exact: exact, remaining: &remaining)
    }

    private func withSplitIDs(exact: [Set<String>: String], remaining: inout [String]) -> LayoutNode {
        switch self {
        case .leaf:
            return self
        case .split(_, let horizontal, let ratio, let first, let second):
            let id = exact[paneIDs] ?? (remaining.isEmpty ? nil : remaining.removeFirst())
            return .split(
                splitID: id, horizontal: horizontal, ratio: ratio,
                first: first.withSplitIDs(exact: exact, remaining: &remaining),
                second: second.withSplitIDs(exact: exact, remaining: &remaining)
            )
        }
    }

    /// Structural equality ignoring split identity; ratios compare within a pixel's slack.
    func matches(_ other: LayoutNode) -> Bool {
        switch (self, other) {
        case let (.leaf(pane, tabs, active), .leaf(otherPane, otherTabs, otherActive)):
            return pane == otherPane && tabs == otherTabs && (active == nil || active == otherActive)
        case let (.split(_, horizontal, ratio, first, second), .split(_, otherHorizontal, otherRatio, otherFirst, otherSecond)):
            return horizontal == otherHorizontal
                && abs(ratio - otherRatio) <= CloudLayoutSyncPlanner.ratioTolerance
                && first.matches(otherFirst) && second.matches(otherSecond)
        default:
            return false
        }
    }

    var json: [String: Any] {
        switch self {
        case .leaf(let paneID, let tabIDs, let active):
            var object: [String: Any] = ["kind": "leaf", "pane_id": paneID, "tab_ids": tabIDs]
            if let active { object["active_tab_id"] = active }
            return object
        case .split(let splitID, let horizontal, let ratio, let first, let second):
            return [
                "kind": "split",
                "split_id": splitID ?? "",
                "direction": horizontal ? "horizontal" : "vertical",
                "ratio": min(0.95, max(0.05, ratio.isFinite ? ratio : 0.5)),
                "first": first.json,
                "second": second.json,
            ]
        }
    }
}
