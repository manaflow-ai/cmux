import AppKit

extension ChatController {
    /// A press on a question card's option or Send (HomeQuestionRowProvider).
    struct QuestionTarget: Equatable { var ref: PartRef; var target: HomeQuestionRowProvider.Target }
    func questionTarget(at point: CGPoint) -> QuestionTarget? {
        guard let hit = demo?.hit(point), case .custom(let custom) = hit.row.part,
              let card = HomeQuestionRowProvider.payload(custom),
              let target = HomeQuestionRowProvider.target(at: CGPoint(x: point.x - hit.body.minX, y: point.y - hit.body.minY),
                                                          card, width: hit.body.width)
        else { return nil }
        return QuestionTarget(ref: hit.row.ref, target: target)
    }
    func questionClicked(at point: CGPoint) -> Bool {
        guard let target = questionTarget(at: point) else { return false }
        questionAction?(target.ref, target.target)
        return true
    }
}
