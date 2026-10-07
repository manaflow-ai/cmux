#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Something up the responder chain that replays a row's send effect.
@MainActor
protocol ConversationEffectReplayHandling: AnyObject {
    func replayEffect(rowID: String)
}

/// VoiceOver actions owned by send effects (kept apart from other actions).
final class EffectAccessibilityAction: UIAccessibilityCustomAction {}

extension MessageCell {
    func installEffectViews() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrow.counterclockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        config.imagePadding = 3
        config.contentInsets = .zero
        config.baseForegroundColor = ConversationTheme.secondaryText
        var title = AttributeContainer()
        title.font = ConversationTheme.footerFont
        config.attributedTitle = AttributedString(ConversationEffectStrings.replay, attributes: title)
        replayButton.configuration = config
        replayButton.isHidden = true
        replayButton.accessibilityIdentifier = "conversation.message.replay"
        replayButton.isAccessibilityElement = false
        replayButton.addAction(UIAction { [weak self] _ in self?.requestReplay() }, for: .touchUpInside)
        shiftable.addSubview(replayButton)
    }

    func resetEffects() {
        effectStage?.layer.removeAllAnimations()
        effectStage?.removeFromSuperview()
        effectStage = nil
        bubble.alpha = 1
        textLabel.alpha = 1
        layer.zPosition = 0
        inkView?.removeFromSuperview()
        inkView = nil
        textLabel.layer.mask = nil
        replayButton.isHidden = true
    }

    func configureEffects(model: MessageRowModel, layout: MessageCellLayout) {
        let effect = model.message.effect
        if let frame = layout.replayFrame {
            replayButton.isHidden = false
            let size = replayButton.intrinsicContentSize
            let x = model.isOutgoing ? frame.maxX - size.width : frame.minX
            replayButton.frame = CGRect(x: x, y: frame.midY - 14, width: size.width, height: 28)
        } else {
            replayButton.isHidden = true
        }

        if effect == .invisibleInk, let bubbleFrame = layout.bubbleFrame, layout.textFrame != nil {
            let ink = inkView ?? InvisibleInkView()
            if inkView == nil {
                shiftable.insertSubview(ink, aboveSubview: textLabel)
                inkView = ink
            }
            ink.frame = bubbleFrame
            let side: BubbleShape.Side = model.isOutgoing ? .trailing : .leading
            ink.attach(cover: textLabel, bubblePath: BubbleShape.path(in: CGRect(origin: .zero, size: bubbleFrame.size), side: side, tail: model.showsTail).cgPath, outgoing: model.isOutgoing)
            if ink.rowID != model.rowID {
                ink.rowID = model.rowID
                ink.cover(animated: false)
            }
            ink.setNeedsLayout()
        } else if let ink = inkView {
            ink.removeFromSuperview()
            inkView = nil
            textLabel.layer.mask = nil
        }

        // VoiceOver speaks the row through `accessibility.bubble`; the
        // controller adds `effectAccessibility` there (ink, effect, actions).
    }

    /// The bubble element's effect additions: Invisible Ink keeps the text
    /// unspoken until revealed, the value names the effect, and Replay /
    /// Reveal run the same paths as the button and touch.
    func effectAccessibility(revealedLabel: String) -> (hiddenLabel: String?, value: String?, actions: [UIAccessibilityCustomAction]) {
        guard let model else { return (nil, nil, []) }
        var hiddenLabel: String?
        if let ink = inkView, !ink.isRevealed {
            hiddenLabel = [model.senderName, ConversationEffectStrings.inkHidden].compactMap { $0 }.joined(separator: ", ")
        }
        var actions: [UIAccessibilityCustomAction] = []
        if cellLayout?.replayFrame != nil {
            actions.append(EffectAccessibilityAction(name: ConversationEffectStrings.replay) { [weak self] _ in
                self?.requestReplay()
                return true
            })
        }
        if inkView != nil {
            actions.append(EffectAccessibilityAction(name: ConversationEffectStrings.reveal) { [weak self] _ in
                guard let self, let ink = self.inkView else { return false }
                ink.revealAll()
                ink.scheduleRecover()
                self.accessibility.bubble.accessibilityLabel = revealedLabel
                return true
            })
        }
        return (hiddenLabel, model.message.effect?.sentWithDescription, actions)
    }

    private func requestReplay() {
        guard let rowID = model?.rowID else { return }
        var responder: UIResponder? = next
        while let current = responder {
            if let handler = current as? any ConversationEffectReplayHandling {
                handler.replayEffect(rowID: rowID)
                return
            }
            responder = current.next
        }
    }

    // MARK: Invisible Ink touches

    /// `point` is in this cell's coordinates.
    func revealInk(at point: CGPoint) {
        guard let ink = inkView else { return }
        ink.reveal(at: ink.convert(point, from: self))
    }

    func inkTouchesEnded() {
        inkView?.scheduleRecover()
    }

    func inkContains(_ point: CGPoint) -> Bool {
        guard let ink = inkView else { return false }
        return ink.bounds.insetBy(dx: -8, dy: -8).contains(ink.convert(point, from: self))
    }

    // MARK: Bubble effects

    /// Plays Slam, Loud or Gentle on a copy of this row's bubble. The real
    /// bubble and text hide until it finishes. `onImpact` fires when Slam lands.
    func playBubbleEffect(
        _ effect: ConversationMessageEffect,
        reduceMotion: Bool,
        onImpact: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let model, let layout = cellLayout, let bubbleFrame = layout.bubbleFrame, let textFrame = layout.textFrame,
              effect.kind == .bubble, effect != .invisibleInk else {
            completion?()
            return
        }
        effectStage?.layer.removeAllAnimations()
        effectStage?.removeFromSuperview()
        let stage = MessageBubbleStage()
        stage.configure(
            side: model.isOutgoing ? .trailing : .leading,
            tail: model.showsTail,
            fill: bubble.fillColor,
            text: textLabel.attributedText ?? NSAttributedString(),
            bubbleFrame: bubbleFrame,
            textFrame: textFrame
        )
        shiftable.insertSubview(stage, aboveSubview: inkView ?? textLabel)
        effectStage = stage
        bubble.alpha = 0
        textLabel.alpha = 0
        // Grows past its row: draw above the neighbors while it plays.
        layer.zPosition = 10
        if effect == .slam, !reduceMotion, let onImpact {
            let impact = ConversationBubbleEffectAnimation.slamImpactMarker()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak stage] in
                guard stage?.superview != nil else { return }
                onImpact()
            }
            stage.layer.add(impact, forKey: "impact")
            CATransaction.commit()
        }
        stage.play(effect, side: model.isOutgoing ? .trailing : .leading, reduceMotion: reduceMotion) { [weak self, weak stage] in
            guard let self, let stage, self.effectStage === stage else { return }
            stage.removeFromSuperview()
            self.effectStage = nil
            self.bubble.alpha = 1
            self.textLabel.alpha = 1
            self.layer.zPosition = 0
            completion?()
        }
    }

    var isPlayingBubbleEffect: Bool { effectStage != nil }

    /// A copy of this row's bubble for screen effects (Echo).
    func makeBubbleCopy() -> UIView? {
        guard let model, let layout = cellLayout, let bubbleFrame = layout.bubbleFrame, let textFrame = layout.textFrame else { return nil }
        let copy = MessageBubbleStage()
        copy.configure(
            side: model.isOutgoing ? .trailing : .leading,
            tail: model.showsTail,
            fill: bubble.fillColor,
            text: textLabel.attributedText ?? NSAttributedString(),
            bubbleFrame: bubbleFrame,
            textFrame: textFrame
        )
        return copy
    }

    /// The bubble (or emoji) frame in `view`'s coordinates.
    func effectAnchor(in view: UIView) -> CGRect? {
        guard let layout = cellLayout, let frame = layout.bubbleFrame ?? layout.emojiFrame else { return nil }
        return shiftable.convert(frame, to: view)
    }
}
#endif
