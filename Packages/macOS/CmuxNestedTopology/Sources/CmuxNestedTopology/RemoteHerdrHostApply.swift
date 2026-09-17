public import Foundation

/// One host verb. Order in a list is load-bearing (tmux apply order).
public struct RemoteHerdrHostAction: Hashable, Sendable {
    /// Verb name (`create_panel`, `rebuild_tree`, `impose_divider`, …).
    public var op: String
    /// Target Herdr pane id when the verb is pane-scoped.
    public var paneID: String?
    /// Existing pane to split from (`expand_leaf`).
    public var splitFromPaneID: String?
    /// Split axis.
    public var orientation: RemoteHerdrSplitOrientation?
    /// Divider fraction.
    public var fraction: Double?
    /// Exact first-child extent in points, when metrics exist.
    public var firstExtent: Double?
    /// True when the new pane is the first child.
    public var insertFirst: Bool
    /// Split identity used to skip a held drag.
    public var splitKey: String?

    /// Creates a host verb.
    public init(
        op: String,
        paneID: String? = nil,
        splitFromPaneID: String? = nil,
        orientation: RemoteHerdrSplitOrientation? = nil,
        fraction: Double? = nil,
        firstExtent: Double? = nil,
        insertFirst: Bool = false,
        splitKey: String? = nil
    ) {
        self.op = op
        self.paneID = paneID
        self.splitFromPaneID = splitFromPaneID
        self.orientation = orientation
        self.fraction = fraction
        self.firstExtent = firstExtent
        self.insertFirst = insertFirst
        self.splitKey = splitKey
    }
}

/// Linearizes one reconcile + impose pass into host verbs.
///
/// AppKit applies these. This type does not import Bonsplit.
public enum RemoteHerdrHostApply {
    /// Walk the binary tree and emit one ``impose_divider`` per split.
    public static func dividerActions(
        _ node: RemoteHerdrDividerNode,
        heldSplitKey: String? = nil,
        keyPrefix: String = "s"
    ) -> [RemoteHerdrHostAction] {
        var actions: [RemoteHerdrHostAction] = []
        walk(node, key: keyPrefix, heldSplitKey: heldSplitKey, into: &actions)
        return actions
    }

    /// Tmux apply order: create panels, close leftovers, mutate tree, impose, focus.
    public static func actions(
        result: RemoteHerdrReconcileResult,
        plan: RemoteHerdrImposePlan
    ) -> [RemoteHerdrHostAction] {
        var actions: [RemoteHerdrHostAction] = []
        for paneID in result.createdPaneIDs {
            actions.append(RemoteHerdrHostAction(op: "create_panel", paneID: paneID))
        }
        for paneID in result.closedPaneIDs {
            actions.append(RemoteHerdrHostAction(op: "close_panel", paneID: paneID))
        }
        switch plan.treeAction {
        case .rebuild:
            actions.append(RemoteHerdrHostAction(op: "rebuild_tree"))
        case .keep:
            actions.append(RemoteHerdrHostAction(op: "keep_tree"))
        case let .expandLeaf(expansion):
            actions.append(
                RemoteHerdrHostAction(
                    op: "expand_leaf",
                    paneID: expansion.newPaneID,
                    splitFromPaneID: expansion.existingPaneID,
                    orientation: expansion.orientation,
                    fraction: expansion.fraction,
                    insertFirst: expansion.insertFirst
                )
            )
        case let .removeLeaf(paneID):
            actions.append(RemoteHerdrHostAction(op: "remove_leaf", paneID: paneID))
        }
        actions.append(contentsOf: dividerActions(plan.dividerTree, heldSplitKey: plan.heldSplitKey))
        if let focus = plan.focusPaneID {
            actions.append(RemoteHerdrHostAction(op: "focus", paneID: focus))
        }
        return actions
    }

    private static func walk(
        _ node: RemoteHerdrDividerNode,
        key: String,
        heldSplitKey: String?,
        into actions: inout [RemoteHerdrHostAction]
    ) {
        switch node {
        case .leaf:
            return
        case let .split(orientation, fraction, firstExtent, first, second):
            if heldSplitKey == nil || key != heldSplitKey {
                actions.append(
                    RemoteHerdrHostAction(
                        op: "impose_divider",
                        orientation: orientation,
                        fraction: fraction,
                        firstExtent: firstExtent,
                        splitKey: key
                    )
                )
            }
            walk(first, key: "\(key).0", heldSplitKey: heldSplitKey, into: &actions)
            walk(second, key: "\(key).1", heldSplitKey: heldSplitKey, into: &actions)
        }
    }
}
