#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

/// Formatting lives in the storage's semantic keys; fonts and the effect
/// overlay are derived from them after every change (see the iOS composer).
extension MacComposerTextView {
    var textRuns: [ConversationTextRun] { ConversationRichText.runs(in: textStorage ?? NSTextStorage()) }

    func setText(_ text: String, runs: [ConversationTextRun]) {
        let string = NSMutableAttributedString(string: text, attributes: baseTypingAttributes)
        ConversationRichText.apply(runs, to: string)
        textStorage?.setAttributedString(string)
        restyle()
        typingAttributes = baseTypingAttributes
    }

    func resetFormatting() {
        typingAttributes = baseTypingAttributes
        effectLayer.clear()
    }

    var activeStyle: ConversationTextStyle {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            return ConversationTextStyle(rawValue: typingAttributes[.conversationTextStyle] as? Int ?? 0)
        }
        return ConversationTextStyle.all.reduce(into: ConversationTextStyle()) { result, entry in
            if ConversationRichText.range(range, of: storage, hasAll: entry.style) { result.insert(entry.style) }
        }
    }

    var activeEffect: ConversationTextEffect? {
        let range = effectTargetRange
        guard range.length > 0, let storage = textStorage else {
            return (typingAttributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
        }
        return ConversationRichText.commonEffect(in: range, of: storage)
    }

    /// Effects apply to the selection, or to the whole draft at a caret.
    private var effectTargetRange: NSRange {
        let range = selectedRange()
        return range.length > 0 ? range : NSRange(location: 0, length: textStorage?.length ?? 0)
    }

    func toggle(_ style: ConversationTextStyle) {
        let range = selectedRange()
        if range.length > 0, let storage = textStorage, shouldChangeText(in: range, replacementString: nil) {
            ConversationRichText.toggle(style, in: range, of: storage)
            didChangeText()
        } else {
            var current = ConversationTextStyle(rawValue: typingAttributes[.conversationTextStyle] as? Int ?? 0)
            if current.contains(style) { current.remove(style) } else { current.insert(style) }
            let effect = (typingAttributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
            typingAttributes = styledTypingAttributes(style: current, effect: effect)
        }
        onFormattingChanged?()
    }

    func toggle(_ effect: ConversationTextEffect) {
        let range = effectTargetRange
        if range.length > 0, let storage = textStorage, shouldChangeText(in: range, replacementString: nil) {
            ConversationRichText.toggle(effect, in: range, of: storage)
            didChangeText()
        } else {
            let style = ConversationTextStyle(rawValue: typingAttributes[.conversationTextStyle] as? Int ?? 0)
            let current = (typingAttributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
            typingAttributes = styledTypingAttributes(style: style, effect: current == effect ? nil : effect)
        }
        onFormattingChanged?()
    }

    /// Typing attributes with only the semantic formatting kept: text typed
    /// next to a mention does not inherit its bold or color.
    func clearTypingDecorations() {
        let style = ConversationTextStyle(rawValue: typingAttributes[.conversationTextStyle] as? Int ?? 0)
        let effect = (typingAttributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
        typingAttributes = styledTypingAttributes(style: style, effect: effect)
    }

    private func styledTypingAttributes(style: ConversationTextStyle, effect: ConversationTextEffect?) -> [NSAttributedString.Key: Any] {
        var attributes = baseTypingAttributes
        if !style.isEmpty { attributes[.conversationTextStyle] = style.rawValue }
        if let effect { attributes[.conversationTextEffect] = effect.rawValue }
        let probe = NSMutableAttributedString(string: "x", attributes: attributes)
        ConversationRichTextStyler.applyDisplayAttributes(to: probe, baseFont: MacConversationTheme.bodyFont, lineHeight: MacConversationTheme.lineHeight)
        return probe.attributes(at: 0, effectiveRange: nil)
    }

    /// Re-derives fonts and decorations from the semantic keys. Skipped while
    /// the input method holds marked text.
    func restyle() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        if storage.length > 0 {
            let selection = selectedRanges
            let typing = typingAttributes
            storage.beginEditing()
            ConversationRichTextStyler.applyDisplayAttributes(to: storage, baseFont: MacConversationTheme.bodyFont, lineHeight: MacConversationTheme.lineHeight)
            decorateStorage?(storage)
            storage.endEditing()
            selectedRanges = selection
            typingAttributes = typing
        }
        refreshEffects()
    }

    func refreshEffects() {
        guard let storage = textStorage, storage.length > 0, ConversationRichTextStyler.hasEffects(storage),
              let container = textContainer else {
            effectLayer.clear()
            return
        }
        effectLayer.frame = bounds
        let origin = textContainerOrigin
        effectiveAppearance.performAsCurrentDrawingAppearance {
            effectLayer.update(
                text: storage,
                textSize: CGSize(width: container.size.width, height: bounds.height),
                textOrigin: origin,
                scale: window?.backingScaleFactor ?? 2,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                seed: 0
            )
        }
    }

    // MARK: Menus

    func formatMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "conversation.textFormat.menu", defaultValue: "Format", bundle: .module), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let active = activeStyle
        for (style, _) in ConversationTextStyle.all {
            let entry = NSMenuItem(title: Self.styleName(style), action: #selector(formatItemChosen(_:)), keyEquivalent: Self.styleKey(style))
            entry.keyEquivalentModifierMask = .command
            entry.target = self
            entry.tag = style.rawValue
            entry.state = active.contains(style) ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    func textEffectsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "conversation.textEffects.title", defaultValue: "Text Effects", bundle: .module), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let active = activeEffect
        for effect in ConversationTextEffect.allCases {
            let entry = NSMenuItem(title: Self.effectName(effect), action: #selector(effectItemChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = effect.rawValue
            entry.state = active == effect ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc func formatItemChosen(_ sender: NSMenuItem) {
        toggle(ConversationTextStyle(rawValue: sender.tag))
    }

    @objc func effectItemChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let effect = ConversationTextEffect(rawValue: raw) else { return }
        toggle(effect)
    }

    private static func styleKey(_ style: ConversationTextStyle) -> String {
        switch style {
        case .bold: return "b"
        case .italic: return "i"
        case .underline: return "u"
        default: return ""
        }
    }

    static func styleName(_ style: ConversationTextStyle) -> String {
        switch style {
        case .bold: return String(localized: "conversation.textStyle.bold", defaultValue: "Bold", bundle: .module)
        case .italic: return String(localized: "conversation.textStyle.italic", defaultValue: "Italic", bundle: .module)
        case .underline: return String(localized: "conversation.textStyle.underline", defaultValue: "Underline", bundle: .module)
        default: return String(localized: "conversation.textStyle.strikethrough", defaultValue: "Strikethrough", bundle: .module)
        }
    }

    static func effectName(_ effect: ConversationTextEffect) -> String {
        switch effect {
        case .big: return String(localized: "conversation.textEffect.big", defaultValue: "Big", bundle: .module)
        case .small: return String(localized: "conversation.textEffect.small", defaultValue: "Small", bundle: .module)
        case .shake: return String(localized: "conversation.textEffect.shake", defaultValue: "Shake", bundle: .module)
        case .nod: return String(localized: "conversation.textEffect.nod", defaultValue: "Nod", bundle: .module)
        case .explode: return String(localized: "conversation.textEffect.explode", defaultValue: "Explode", bundle: .module)
        case .ripple: return String(localized: "conversation.textEffect.ripple", defaultValue: "Ripple", bundle: .module)
        case .bloom: return String(localized: "conversation.textEffect.bloom", defaultValue: "Bloom", bundle: .module)
        case .jitter: return String(localized: "conversation.textEffect.jitter", defaultValue: "Jitter", bundle: .module)
        }
    }
}
#endif
