#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Per-controller send-effect state.
@MainActor
struct ConversationEffectsState {
    /// The effect the next composer send carries (set by the picker).
    var pendingSendEffect: ConversationMessageEffect?
    /// Rows whose effect plays after the current transcript update applies.
    var queuedRowIDs: [String] = []
    var screenView: ScreenEffectView?
    var inkRecognizer: InkRevealGestureRecognizer?
    var inkDelegate: InkRevealGestureDelegate?
}

/// Why an effect plays. Reduce Motion stops automatic playback of screen
/// effects and turns bubble effects into a fade; an explicit Replay still plays.
enum EffectPlayReason {
    case sent
    case arrived
    case replay
}

extension ConversationViewController: ConversationEffectReplayHandling {
    var prefersReducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    func installEffects() {
        let recognizer = InkRevealGestureRecognizer(target: nil, action: nil)
        let delegate = InkRevealGestureDelegate()
        recognizer.delegate = delegate
        recognizer.cellAt = { [weak self] point in
            guard let self, let cell = self.messageCell(at: point, requireContentHit: false) else { return nil }
            return cell.inkContains(cell.convert(point, from: self.collectionView)) ? cell : nil
        }
        collectionView.addGestureRecognizer(recognizer)
        effects.inkRecognizer = recognizer
        effects.inkDelegate = delegate
    }

    // MARK: Picker

    func composerDidLongPressSend(_ composer: ConversationComposerView) {
        guard editingMessageID == nil, presentedViewController == nil else { return }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let wasEditing = composer.textView.isFirstResponder
        let sendFrame = composer.sendButton.convert(composer.sendButton.bounds, to: nil)
        let picker = MessageEffectPickerViewController(
            text: NSAttributedString(string: text),
            sendButtonFrame: sendFrame,
            reduceMotion: prefersReducedMotion
        )
        picker.onSend = { [weak self, weak picker] effect in
            guard let self else { return }
            picker?.dismiss(animated: true) {
                self.effects.pendingSendEffect = effect
                self.composerDidTapSend(self.composer)
                self.effects.pendingSendEffect = nil
                if wasEditing { self.composer.textView.becomeFirstResponder() }
            }
        }
        picker.onCancel = { [weak self, weak picker] in
            picker?.dismiss(animated: true) {
                if wasEditing { self?.composer.textView.becomeFirstResponder() }
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        present(picker, animated: true)
    }

    // MARK: Playback

    /// Called while classifying inserted rows. Returns true when the row's
    /// arrival animation should be skipped because a bubble effect is its entrance.
    func queueArrivalEffect(_ model: MessageRowModel) -> Bool {
        guard let effect = model.message.effect else { return false }
        effects.queuedRowIDs.append(model.rowID)
        return effect.kind == .bubble && effect != .invisibleInk
    }

    /// Plays the effects queued by the update that just applied.
    func playQueuedEffects() {
        let ids = effects.queuedRowIDs
        effects.queuedRowIDs = []
        for rowID in ids {
            playEffect(rowID: rowID, reason: .arrived)
        }
    }

    func playSentEffect(rowID: String) {
        playEffect(rowID: rowID, reason: .sent)
    }

    func replayEffect(rowID: String) {
        playEffect(rowID: rowID, reason: .replay)
    }

    func playEffect(rowID: String, reason: EffectPlayReason) {
        guard let indexPath = indexPath(for: rowID), case let .message(model) = rows[indexPath.item],
              let effect = model.message.effect else { return }
        let reduce = prefersReducedMotion
        switch effect.kind {
        case .bubble:
            guard effect != .invisibleInk else { return }
            collectionView.layoutIfNeeded()
            guard let cell = collectionView.cellForItem(at: indexPath) as? MessageCell else { return }
            cell.playBubbleEffect(effect, reduceMotion: reduce, onImpact: { [weak self, weak cell] in
                self?.shakeNeighbors(of: cell)
            })
        case .screen:
            if reduce, reason != .replay { return }
            playScreenEffect(effect, rowID: rowID)
        }
    }

    private func playScreenEffect(_ effect: ConversationMessageEffect, rowID: String) {
        effects.screenView?.stop()
        effects.screenView?.removeFromSuperview()
        let overlay = ScreenEffectView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        effects.screenView = overlay
        collectionView.layoutIfNeeded()
        let cell = indexPath(for: rowID).flatMap { collectionView.cellForItem(at: $0) as? MessageCell }
        let fallback = CGRect(x: view.bounds.width - layoutMargin - 200, y: composerContainer.frame.minY - 60, width: 200, height: 44)
        let anchor = cell?.effectAnchor(in: overlay) ?? fallback
        overlay.play(effect, anchor: anchor, bubble: { [weak cell] in cell?.makeBubbleCopy() }) { [weak self, weak overlay] in
            guard let self, let overlay, self.effects.screenView === overlay else { return }
            overlay.removeFromSuperview()
            self.effects.screenView = nil
        }
    }

    /// Slam's impact jolts the rest of the transcript away from the bubble.
    func shakeNeighbors(of source: MessageCell?) {
        guard let source else { return }
        let sourceY = source.frame.midY
        for cell in collectionView.visibleCells where cell !== source {
            let direction: CGFloat = cell.frame.midY < sourceY ? -1 : 1
            let distance = abs(cell.frame.midY - sourceY)
            let amplitude = max(1.5, 8 - distance / 70) * direction
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.y")
            shake.values = [0, amplitude, -amplitude * 0.45, amplitude * 0.18, 0]
            shake.keyTimes = [0, 0.16, 0.45, 0.72, 1]
            shake.duration = 0.4
            shake.isAdditive = true
            cell.layer.add(shake, forKey: "effect.slamShake")
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}

/// Tracks a finger over an Invisible Ink bubble without claiming the touch:
/// it never begins, so scrolling, taps and long presses behave as before.
final class InkRevealGestureRecognizer: UIGestureRecognizer {
    var cellAt: ((CGPoint) -> MessageCell?)?
    private weak var activeCell: MessageCell?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard activeCell == nil, let touch = touches.first, let view,
              let cell = cellAt?(touch.location(in: view)) else {
            if activeCell == nil { state = .failed }
            return
        }
        activeCell = cell
        cell.revealInk(at: touch.location(in: cell))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let cell = activeCell else { return }
        for touch in touches {
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                cell.revealInk(at: sample.location(in: cell))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish()
        state = .failed
    }

    override func reset() {
        super.reset()
        finish()
    }

    private func finish() {
        activeCell?.inkTouchesEnded()
        activeCell = nil
    }
}

final class InkRevealGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
