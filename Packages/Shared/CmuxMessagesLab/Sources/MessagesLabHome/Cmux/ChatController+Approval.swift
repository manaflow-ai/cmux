import AppKit

extension ChatController {
    struct ApprovalTarget: Equatable { var ref: PartRef; var allow: Bool }
    func approvalTarget(at point: CGPoint) -> ApprovalTarget? {
        guard let hit = demo?.hit(point), case .custom(let custom) = hit.row.part,
              let card = HomeApprovalRowProvider.payload(custom),
              let allow = HomeApprovalRowProvider.button(at: CGPoint(x: point.x - hit.body.minX, y: point.y - hit.body.minY), card, width: hit.body.width)
        else { return nil }
        return ApprovalTarget(ref: hit.row.ref, allow: allow)
    }
    func approvalClicked(at point: CGPoint) -> Bool {
        guard let target = approvalTarget(at: point) else { return false }
        approvalDecision?(target.ref, target.allow)
        return true
    }
}
