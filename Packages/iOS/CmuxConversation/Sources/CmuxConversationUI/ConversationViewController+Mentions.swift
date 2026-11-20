#if canImport(UIKit)
import CmuxConversationCore
import UIKit

extension ConversationViewController: UIPopoverPresentationControllerDelegate {
    /// Mentions work in group conversations only, as in Messages.
    func installMentions() {
        let controller = composer.mentionController
        controller.participants = { [weak self] in
            guard let info = self?.store.info, info.kind == .group else { return [] }
            return info.participants
        }
        controller.onQueryChange = { [weak self] query in self?.showMentionSuggestions(query) }
        view.addSubview(controller.suggestions)
    }

    private func showMentionSuggestions(_ query: ConversationMentionQuery?) {
        let suggestions = composer.mentionController.suggestions
        guard let query, !query.matches.isEmpty, composer.textView.isFirstResponder else {
            guard !suggestions.isHidden else { return }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
                suggestions.alpha = 0
            } completion: { finished in
                if finished, suggestions.alpha == 0 { suggestions.isHidden = true }
            }
            return
        }
        suggestions.configure(matches: query.matches)
        let field = composer.fieldFrame(in: view)
        let height = suggestions.preferredHeight
        suggestions.frame = CGRect(x: field.minX, y: field.minY - 8 - height, width: min(field.width, 280), height: height)
        view.bringSubviewToFront(suggestions)
        guard suggestions.isHidden || suggestions.alpha < 1 else { return }
        suggestions.isHidden = false
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            suggestions.alpha = 1
        }
    }

    /// Tapping a mention shows that participant's card.
    func presentMentionCard(participantID: String, at point: CGPoint) {
        guard let participant = store.info?.participant(participantID) else { return }
        let card = ConversationMentionCardViewController(participant: participant)
        card.modalPresentationStyle = .popover
        if let popover = card.popoverPresentationController {
            popover.sourceView = collectionView
            popover.sourceRect = CGRect(origin: point, size: .zero).insetBy(dx: -4, dy: -4)
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = self
        }
        present(card, animated: true)
    }

    public func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
#endif
