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

    public func dropEnded(committed: TabDropProposal?) {
        let payload = groups.dropPayload
        groups.dropPayload = nil
        guard let committed, case .strip(let stripID, _, _) = committed.kind, stripID == model.stripID, let payload else {
            hidePhantom()
            return
        }
        switch payload {
        case .tab(let id, _): commitPhantom(tabID: TabID(id))
        case .tabGroup(let id, _, _, _): commitGroupPhantom(groupID: TabGroupID(id))
        }
    }
}
