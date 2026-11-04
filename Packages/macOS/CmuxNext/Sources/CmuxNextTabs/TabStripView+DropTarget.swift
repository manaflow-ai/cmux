public import CmuxNextDesign
public import AppKit

// Adapts the strip's phantom-gap API to the shared drop-target protocol.
extension TabStripView: TabDropTargetProviding {
    public func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        let target: TabStripDropTarget?
        switch payload {
        case .tab:
            target = updatePhantom(atScreenPoint: screenPoint)
        case .tabGroup(_, _, _, let width):
            target = updateGroupPhantom(atScreenPoint: screenPoint, width: width)
        }
        groups.dropPayload = target == nil ? nil : payload
        guard let target else { return nil }
        return TabDropProposal(
            kind: .strip(stripID: target.stripID, index: target.index, groupID: target.groupID?.rawValue),
            highlightFrame: target.ghostFrame,
            ghostFrame: target.ghostFrame
        )
    }

    public func dropExited() {
        groups.dropPayload = nil
        hidePhantom()
    }

    @discardableResult
    public func dropEnded(committed: TabDropProposal?) -> (@MainActor (Bool) -> Void)? {
        let payload = groups.dropPayload
        groups.dropPayload = nil
        guard let committed, case .strip(let stripID, _, _) = committed.kind, stripID == model.stripID, let payload else {
            hidePhantom()
            return nil
        }
        let commitID = UUID()
        dropCommitID = commitID
        // Snapshot both sides of the commit: rollback reverts only what this
        // drop changed and keeps an unrelated pending reorder or regroup.
        let before = (order: orderOverride, membership: groups.membershipOverride)
        switch payload {
        case .tab(let id, _): commitPhantom(tabID: TabID(id))
        case .tabGroup(let id, _, _, _): commitGroupPhantom(groupID: TabGroupID(id))
        }
        let after = (order: orderOverride, membership: groups.membershipOverride)
        return { [weak self] landed in
            guard let self, dropCommitID == commitID else { return }
            dropCommitID = nil
            guard !landed else { return }
            pendingDrop = nil
            // A new drag can hover here while this move is still waiting.
            // Its gap belongs to its pointer, not to the failed commit.
            if phantomPoint == nil {
                dropPlaceholderIndex = nil
                dropPlaceholderGroup = nil
                groups.phantomWidth = nil
            }
            if after.order != before.order, orderOverride == after.order { orderOverride = before.order }
            if after.membership != before.membership, groups.membershipOverride == after.membership {
                groups.membershipOverride = before.membership
            }
            sync(fromModel: false)
        }
    }
}
