import AppKit

extension ChatController {
    /// A click on a failed-turn card's button goes to the projection (`turnFailureAction`).
    func turnFailureClicked(at point: CGPoint) -> Bool {
        guard let hit = demo?.hit(point), case .custom(let custom) = hit.row.part,
              let card = HomeTurnFailureRowProvider.payload(custom),
              let action = HomeTurnFailureRowProvider.action(at: CGPoint(x: point.x - hit.body.minX, y: point.y - hit.body.minY),
                                                            card, width: hit.body.width)
        else { return false }
        turnFailureAction?(hit.row.ref, action)
        return true
    }
}
