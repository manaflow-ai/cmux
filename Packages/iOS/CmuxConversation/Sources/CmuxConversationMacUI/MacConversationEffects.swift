#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

// macOS send effects: Message Effects in the apps (+) menu, bubble effects
// played on a copy of the row's bubble, Invisible Ink revealed on hover,
// screen effects over the window, and Replay under the message. The
// animations themselves are the shared ones in CmuxConversationGeometry.

extension ConversationMessageEffect {
    var animationKind: ConversationEffectAnimationKind {
        ConversationEffectAnimationKind(rawValue: rawValue) ?? .slam
    }

    var macLocalizedName: String {
        switch self {
        case .slam: return String(localized: "conversation.effect.slam", defaultValue: "Slam", bundle: .module)
        case .loud: return String(localized: "conversation.effect.loud", defaultValue: "Loud", bundle: .module)
        case .gentle: return String(localized: "conversation.effect.gentle", defaultValue: "Gentle", bundle: .module)
        case .invisibleInk: return String(localized: "conversation.effect.invisibleInk", defaultValue: "Invisible Ink", bundle: .module)
        case .echo: return String(localized: "conversation.effect.echo", defaultValue: "Echo", bundle: .module)
        case .spotlight: return String(localized: "conversation.effect.spotlight", defaultValue: "Spotlight", bundle: .module)
        case .balloons: return String(localized: "conversation.effect.balloons", defaultValue: "Balloons", bundle: .module)
        case .confetti: return String(localized: "conversation.effect.confetti", defaultValue: "Confetti", bundle: .module)
        case .love: return String(localized: "conversation.effect.love", defaultValue: "Love", bundle: .module)
        case .lasers: return String(localized: "conversation.effect.lasers", defaultValue: "Lasers", bundle: .module)
        case .fireworks: return String(localized: "conversation.effect.fireworks", defaultValue: "Fireworks", bundle: .module)
        case .celebration: return String(localized: "conversation.effect.celebration", defaultValue: "Celebration", bundle: .module)
        }
    }
}

enum MacEffectStrings {
    static var replay: String { String(localized: "conversation.effect.replay", defaultValue: "Replay", bundle: .module) }
    static var menu: String { String(localized: "conversation.effect.menu", defaultValue: "Message Effects", bundle: .module) }
    static var bubble: String { String(localized: "conversation.effect.bubble", defaultValue: "Bubble", bundle: .module) }
    static var screen: String { String(localized: "conversation.effect.screen", defaultValue: "Screen", bundle: .module) }
    static var inkHidden: String { String(localized: "conversation.effect.inkHidden", defaultValue: "Hidden with Invisible Ink", bundle: .module) }
    static func sentWith(_ effect: ConversationMessageEffect) -> String {
        String(format: String(localized: "conversation.effect.sentWith", defaultValue: "Sent with %@", bundle: .module), effect.macLocalizedName)
    }
}

/// Something up the responder chain that replays a row's send effect.
@MainActor
protocol MacEffectReplayHandling: AnyObject {
    func replayEffect(rowID: String)
}

// MARK: - Row

extension MacMessageRowView {
    func installEffectViews() {
        replayButton.isBordered = false
        replayButton.bezelStyle = .inline
        replayButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        replayButton.imagePosition = .imageLeading
        replayButton.imageHugsTitle = true
        replayButton.contentTintColor = MacConversationTheme.secondaryText
        replayButton.attributedTitle = NSAttributedString(string: MacEffectStrings.replay, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: MacConversationTheme.secondaryText,
        ])
        replayButton.setAccessibilityIdentifier("conversation.message.replay")
        replayButton.target = self
        replayButton.action = #selector(replayTapped)
        replayButton.isHidden = true
        addSubview(replayButton)
    }

    func configureEffects(_ model: MacMessageRowModel, layout: MacMessageLayout) {
        if let frame = layout.replayFrame {
            replayButton.isHidden = false
            replayButton.sizeToFit()
            let size = replayButton.frame.size
            replayButton.frame = CGRect(x: model.isOutgoing ? frame.maxX - size.width : frame.minX, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        } else {
            replayButton.isHidden = true
        }

        if model.message.effect == .invisibleInk, let bubbleFrame = layout.bubbleFrame {
            let ink = inkLayer ?? CAEmitterLayer()
            if inkLayer == nil {
                layer?.addSublayer(ink)
                inkLayer = ink
            }
            let color = model.isOutgoing ? NSColor.white : (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.4, alpha: 1))
            let reseed = inkRowID != model.rowID || ink.bounds.size != bubbleFrame.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ink.frame = bubbleFrame
            let mask = (ink.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.path = ConversationBubbleGeometry.path(
                in: CGRect(origin: .zero, size: bubbleFrame.size), side: model.isOutgoing ? .trailing : .leading, tail: model.showsTail,
                radius: MacConversationTheme.bubbleCornerRadius, tailWidth: MacConversationTheme.tailWidth, tailDrop: MacConversationTheme.tailDrop, style: .macOS
            )
            ink.mask = mask
            if reseed {
                ConversationInkParticles.configure(ink, size: bubbleFrame.size, color: color.cgColor, scale: window?.backingScaleFactor ?? 2)
            }
            if inkRowID != model.rowID {
                inkRowID = model.rowID
                isInkRevealed = false
            }
            ink.opacity = isInkRevealed ? 0 : 1
            CATransaction.commit()
            textLabel.alphaValue = isInkRevealed ? 1 : 0
            setAccessibilityLabel([model.isOutgoing ? nil : model.senderName, isInkRevealed ? model.message.text : MacEffectStrings.inkHidden].compactMap { $0 }.joined(separator: ", "))
        } else if let ink = inkLayer {
            ink.removeFromSuperlayer()
            inkLayer = nil
            inkRowID = nil
            isInkRevealed = false
            textLabel.alphaValue = 1
        }
        if let effect = model.message.effect {
            setAccessibilityHelp(MacEffectStrings.sentWith(effect))
        } else {
            setAccessibilityHelp(nil)
        }
    }

    /// Messages for Mac reveals Invisible Ink while the pointer is over it.
    func setInkRevealed(_ revealed: Bool) {
        guard let ink = inkLayer, revealed != isInkRevealed else { return }
        isInkRevealed = revealed
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ink.presentation()?.opacity ?? ink.opacity
        fade.toValue = revealed ? 0 : 1
        fade.duration = revealed ? 0.3 : 0.6
        ink.opacity = revealed ? 0 : 1
        ink.add(fade, forKey: "reveal")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade.duration
            textLabel.animator().alphaValue = revealed ? 1 : 0
        }
        if let model {
            setAccessibilityLabel([model.isOutgoing ? nil : model.senderName, revealed ? model.message.text : MacEffectStrings.inkHidden].compactMap { $0 }.joined(separator: ", "))
        }
    }

    @objc private func replayTapped() {
        guard let rowID = model?.rowID else { return }
        var responder: NSResponder? = nextResponder
        while let current = responder {
            if let handler = current as? any MacEffectReplayHandling {
                handler.replayEffect(rowID: rowID)
                return
            }
            responder = current.nextResponder
        }
    }

    /// Plays Slam, Loud or Gentle on a copy of the bubble; the real bubble
    /// and text hide until it finishes.
    func playBubbleEffect(_ effect: ConversationMessageEffect, reduceMotion: Bool, onImpact: (() -> Void)? = nil) {
        guard let model, let layout = rowLayout, let frame = layout.bubbleFrame, let textFrame = layout.textFrame,
              effect.kind == .bubble, effect != .invisibleInk,
              let animation = ConversationBubbleEffectAnimation.make(effect.animationKind, bubbleSize: frame.size, trailing: model.isOutgoing, reduceMotion: reduceMotion),
              let rep = textLabel.bitmapImageRepForCachingDisplay(in: textLabel.bounds) else { return }
        textLabel.cacheDisplay(in: textLabel.bounds, to: rep)
        effectLayer?.removeFromSuperlayer()
        let copy = CALayer()
        copy.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        copy.frame = frame
        let shape = CAShapeLayer()
        shape.frame = copy.bounds
        shape.path = ConversationBubbleGeometry.path(
            in: copy.bounds, side: model.isOutgoing ? .trailing : .leading, tail: model.showsTail,
            radius: MacConversationTheme.bubbleCornerRadius, tailWidth: MacConversationTheme.tailWidth, tailDrop: MacConversationTheme.tailDrop, style: .macOS
        )
        shape.fillColor = bubble.fillColor
        copy.addSublayer(shape)
        let text = CALayer()
        text.contents = rep.cgImage
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.frame = textFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        copy.addSublayer(text)
        layer?.addSublayer(copy)
        effectLayer = copy
        bubble.opacity = 0
        textLabel.alphaValue = 0
        // Grows past its row: draw above the neighbors while it plays.
        let rowLayer = superview?.superview?.layer
        rowLayer?.zPosition = 10
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak copy] in
            MainActor.assumeIsolated {
                guard let self, let copy, self.effectLayer === copy else { return }
                copy.removeFromSuperlayer()
                self.effectLayer = nil
                self.bubble.opacity = 1
                self.textLabel.alphaValue = self.inkLayer == nil || self.isInkRevealed ? 1 : 0
                rowLayer?.zPosition = 0
            }
        }
        copy.add(animation, forKey: "messageEffect")
        CATransaction.commit()
        if effect == .slam, !reduceMotion, let onImpact {
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { onImpact() } }
            copy.add(ConversationBubbleEffectAnimation.slamImpactMarker(), forKey: "impact")
            CATransaction.commit()
        }
    }

    /// A layer copy of the bubble for Echo.
    func bubbleCopyLayer() -> CALayer? {
        guard let layout = rowLayout, let frame = layout.bubbleFrame ?? layout.emojiFrame,
              let rep = bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        cacheDisplay(in: frame, to: rep)
        let copy = CALayer()
        // cacheDisplay draws views, not the bubble's shape layer: paint it in.
        let shape = CAShapeLayer()
        shape.frame = CGRect(origin: .zero, size: frame.size)
        shape.path = bubble.path.map { path in
            var shift = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
            return path.copy(using: &shift) ?? path
        }
        shape.fillColor = bubble.fillColor
        copy.addSublayer(shape)
        let text = CALayer()
        text.frame = shape.frame
        text.contents = rep.cgImage
        copy.addSublayer(text)
        copy.bounds = shape.frame
        return copy
    }
}

// MARK: - Screen overlay

/// A full-window, click-through overlay for screen effects.
final class MacScreenEffectView: MacFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func play(_ effect: ConversationMessageEffect, anchor: CGRect, bubble: (() -> CALayer?)?, completion: @escaping @MainActor () -> Void) {
        guard let layer else { completion(); return }
        ConversationScreenEffect.play(effect.animationKind, in: layer, bounds: bounds, anchor: anchor, scale: window?.backingScaleFactor ?? 2, bubble: bubble, completion: completion)
    }

    func stop() {
        if let layer { ConversationScreenEffect.clear(layer) }
    }
}

// MARK: - Controller

@MainActor
struct MacEffectsState {
    var pendingSendEffect: ConversationMessageEffect?
    var queuedRowIDs: [String] = []
    var screenView: MacScreenEffectView?
}

extension MacConversationViewController: MacEffectReplayHandling {
    var prefersReducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// "Message Effects" in the apps menu: picking one sends the draft with it.
    func effectsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: MacEffectStrings.menu, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let submenu = NSMenu(title: MacEffectStrings.menu)
        func section(_ title: String, _ effects: [ConversationMessageEffect]) {
            if #available(macOS 14.0, *) {
                submenu.addItem(.sectionHeader(title: title))
            } else {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                submenu.addItem(header)
            }
            for effect in effects {
                let entry = MacClosureMenuItem(title: effect.macLocalizedName) { [weak self] in self?.sendWithEffect(effect) }
                entry.setAccessibilityIdentifier("conversation.effects.\(effect.rawValue)")
                submenu.addItem(entry)
            }
        }
        section(MacEffectStrings.bubble, ConversationMessageEffect.bubbleEffects)
        section(MacEffectStrings.screen, ConversationMessageEffect.screenEffects)
        item.submenu = submenu
        item.isEnabled = canSendWithEffect
        return item
    }

    var canSendWithEffect: Bool {
        editingMessageID == nil && !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendWithEffect(_ effect: ConversationMessageEffect) {
        guard canSendWithEffect else { return }
        effects.pendingSendEffect = effect
        composerDidSubmit(composer)
        effects.pendingSendEffect = nil
    }

    /// Classifies an arriving row. Returns true when a bubble effect replaces its grow-in.
    func queueArrivalEffect(_ model: MacMessageRowModel) -> Bool {
        guard let effect = model.message.effect else { return false }
        effects.queuedRowIDs.append(model.rowID)
        return effect.kind == .bubble && effect != .invisibleInk
    }

    func playQueuedEffects() {
        let ids = effects.queuedRowIDs
        effects.queuedRowIDs = []
        for id in ids { playEffect(rowID: id, explicit: false) }
    }

    func replayEffect(rowID: String) {
        playEffect(rowID: rowID, explicit: true)
    }

    func playEffect(rowID: String, explicit: Bool) {
        guard let index = rowIndex[rowID], let model = messageModel(at: index), let effect = model.message.effect else { return }
        let reduce = prefersReducedMotion
        view.layoutSubtreeIfNeeded()
        switch effect.kind {
        case .bubble:
            guard effect != .invisibleInk, let row = rowView(at: index) else { return }
            row.playBubbleEffect(effect, reduceMotion: reduce) { [weak self, weak row] in
                self?.shakeNeighbors(of: row)
            }
        case .screen:
            if reduce, !explicit { return }
            guard let host = view.window?.contentView else { return }
            effects.screenView?.stop()
            effects.screenView?.removeFromSuperview()
            let overlay = MacScreenEffectView(frame: host.bounds)
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay)
            effects.screenView = overlay
            let row = rowView(at: index)
            let anchor = row.flatMap { row in row.rowLayout?.bubbleFrame.map { row.convert($0, to: overlay) } }
                ?? CGRect(x: overlay.bounds.maxX - 220, y: overlay.bounds.maxY - 120, width: 200, height: 32)
            overlay.play(effect, anchor: anchor, bubble: { [weak row] in row?.bubbleCopyLayer() }) { [weak self, weak overlay] in
                guard let self, let overlay, self.effects.screenView === overlay else { return }
                overlay.removeFromSuperview()
                self.effects.screenView = nil
            }
        }
    }

    /// Lab readout: the newest effect row, whether its bubble copy or a
    /// screen overlay is playing, its Replay control and ink state.
    func effectLabState() -> String {
        guard let index = rows.lastIndex(where: { if case let .message(m) = $0 { return m.message.effect != nil } else { return false } }),
              let model = messageModel(at: index) else { return "none" }
        let row = rowView(at: index)
        let screen = effects.screenView.map { $0.layer.map(ConversationScreenEffect.isPlaying) ?? false } ?? false
        return [
            "effect=\(model.message.effect?.rawValue ?? "-")",
            "outgoing=\(model.isOutgoing)",
            "bubbleCopy=\(row?.effectLayer?.animation(forKey: "messageEffect") != nil)",
            "screen=\(screen)",
            "replay=\(row.map { !$0.replayButton.isHidden } ?? false)",
            "ink=\(row?.inkLayer != nil)",
            "inkRevealed=\(row?.isInkRevealed ?? false)",
            "textAlpha=\(row.map { String(format: "%.2f", $0.textLabel.alphaValue) } ?? "-")",
        ].joined(separator: " ")
    }

    /// Slam's impact jolts the visible rows away from the bubble.
    func shakeNeighbors(of source: MacMessageRowView?) {
        guard let source else { return }
        let sourceY = source.convert(source.bounds, to: tableView).midY
        let visible = tableView.rows(in: tableView.visibleRect)
        for index in visible.location..<(visible.location + visible.length) {
            guard let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: false), view !== source.superview,
                  let layer = view.layer else { continue }
            let y = view.convert(view.bounds, to: tableView).midY
            let direction: CGFloat = y < sourceY ? -1 : 1
            let amplitude = max(1.5, 7 - abs(y - sourceY) / 70) * direction
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.y")
            shake.values = [0, amplitude, -amplitude * 0.45, amplitude * 0.18, 0]
            shake.keyTimes = [0, 0.16, 0.45, 0.72, 1]
            shake.duration = 0.4
            shake.isAdditive = true
            layer.add(shake, forKey: "effect.slamShake")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
#endif
