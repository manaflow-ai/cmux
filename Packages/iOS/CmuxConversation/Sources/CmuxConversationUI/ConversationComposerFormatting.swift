#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Formatting state lives in the text storage's semantic keys
/// (`.conversationTextStyle`, `.conversationTextEffect`); fonts and the
/// effect overlay are derived from them after every change.
extension ComposerTextView {
    var textRuns: [ConversationTextRun] { ConversationRichText.runs(in: textStorage) }

    func installTextEffects() {
        layer.addSublayer(effectLayer)
    }

    func setText(_ text: String, runs: [ConversationTextRun]) {
        let string = NSMutableAttributedString(string: text, attributes: baseTypingAttributes)
        ConversationRichText.apply(runs, to: string)
        attributedText = string
        restyle()
        typingAttributes = styledTypingAttributes(style: [], effect: nil)
    }

    func resetFormatting() {
        typingAttributes = baseTypingAttributes
        effectLayer.clear()
    }

    /// The style a Bold/Italic/... toggle would act on: the whole selection,
    /// or the typing attributes at a caret.
    var activeStyle: ConversationTextStyle {
        let range = selectedRange
        guard range.length > 0 else {
            return ConversationTextStyle(rawValue: typingAttributes[.conversationTextStyle] as? Int ?? 0)
        }
        return ConversationTextStyle.all.reduce(into: ConversationTextStyle()) { result, entry in
            if ConversationRichText.range(range, of: textStorage, hasAll: entry.style) { result.insert(entry.style) }
        }
    }

    var activeEffect: ConversationTextEffect? {
        let range = effectTargetRange
        guard range.length > 0 else {
            return (typingAttributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
        }
        return ConversationRichText.commonEffect(in: range, of: textStorage)
    }

    /// Effects apply to the selection, or to the whole draft at a caret.
    private var effectTargetRange: NSRange {
        selectedRange.length > 0 ? selectedRange : NSRange(location: 0, length: textStorage.length)
    }

    func toggle(_ style: ConversationTextStyle) {
        let range = selectedRange
        if range.length > 0 {
            ConversationRichText.toggle(style, in: range, of: textStorage)
            restyle()
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
        if range.length > 0 {
            ConversationRichText.toggle(effect, in: range, of: textStorage)
            restyle()
        } else {
            let style = ConversationTextStyle(rawValue: typingAttributes[.conversationTextStyle] as? Int ?? 0)
            let current = (typingAttributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
            typingAttributes = styledTypingAttributes(style: style, effect: current == effect ? nil : effect)
        }
        onFormattingChanged?()
    }

    /// The draft's base font and pitch: the body metrics, or an emoji-only
    /// draft's large size (the composer swaps `baseTypingAttributes`).
    private var displayBaseFont: UIFont { baseTypingAttributes[.font] as? UIFont ?? ConversationTheme.bodyFont }
    private var displayLineHeight: CGFloat {
        let fixed = (baseTypingAttributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0
        return fixed > 0 ? fixed : displayBaseFont.lineHeight
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
        ConversationRichTextStyler.applyDisplayAttributes(to: probe, baseFont: displayBaseFont, lineHeight: displayLineHeight)
        return probe.attributes(at: 0, effectiveRange: nil)
    }

    /// Re-derives fonts and decorations from the semantic keys. Skipped while
    /// the input method holds marked text.
    func restyle() {
        guard markedTextRange == nil else { return }
        let length = textStorage.length
        if length > 0 {
            let selection = selectedRange
            let typing = typingAttributes
            textStorage.beginEditing()
            ConversationRichTextStyler.applyDisplayAttributes(to: textStorage, baseFont: displayBaseFont, lineHeight: displayLineHeight)
            decorateStorage?(textStorage)
            textStorage.endEditing()
            selectedRange = selection
            typingAttributes = typing
        }
        refreshEffects()
    }

    func refreshEffects() {
        effectLayer.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: max(bounds.height, contentSize.height)))
        guard textStorage.length > 0, ConversationRichTextStyler.hasEffects(textStorage) else {
            effectLayer.clear()
            return
        }
        let size = CGSize(width: textContainer.size.width, height: contentSize.height)
        traitCollection.performAsCurrent {
            effectLayer.update(
                text: textStorage,
                textSize: size,
                textOrigin: CGPoint(x: textContainerInset.left, y: textContainerInset.top),
                scale: max(1, window?.screen.scale ?? traitCollection.displayScale),
                animated: !UIAccessibility.isReduceMotionEnabled,
                seed: 0
            )
        }
    }
}

/// Replaces the keyboard while formatting: Bold/Italic/Underline/Strikethrough
/// toggles above a grid of the eight text effects, each previewing itself.
final class TextEffectsPaletteView: UIInputView {
    private weak var composer: ConversationComposerView?
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let styleBar = UIView()
    private var styleButtons: [(ConversationTextStyle, UIButton)] = []
    private var effectTiles: [(ConversationTextEffect, UIControl, ConversationEffectLabel)] = []

    init(composer: ConversationComposerView) {
        self.composer = composer
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 330), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        accessibilityIdentifier = "conversation.textEffects.palette"

        titleLabel.text = String(localized: "conversation.textEffects.title", defaultValue: "Text Effects", bundle: .module)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = .tertiarySystemFill
        closeButton.layer.cornerRadius = 15
        closeButton.accessibilityLabel = String(localized: "conversation.textEffects.close", defaultValue: "Close", bundle: .module)
        closeButton.accessibilityIdentifier = "conversation.textEffects.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.composer?.hideTextEffects() }, for: .touchUpInside)
        addSubview(closeButton)

        styleBar.backgroundColor = .secondarySystemFill
        styleBar.layer.cornerRadius = 12
        styleBar.layer.cornerCurve = .continuous
        addSubview(styleBar)
        for (style, name) in ConversationTextStyle.all {
            let button = UIButton(type: .custom)
            button.setAttributedTitle(Self.styleGlyph(style), for: .normal)
            button.layer.cornerRadius = 9
            button.layer.cornerCurve = .continuous
            button.accessibilityLabel = Self.styleName(style)
            button.accessibilityIdentifier = "conversation.textEffects.\(name)"
            button.addAction(UIAction { [weak self] _ in self?.composer?.textView.toggle(style) }, for: .touchUpInside)
            styleBar.addSubview(button)
            styleButtons.append((style, button))
        }

        for effect in ConversationTextEffect.allCases {
            let tile = UIControl()
            tile.backgroundColor = .secondarySystemFill
            tile.layer.cornerRadius = 12
            tile.layer.cornerCurve = .continuous
            tile.isAccessibilityElement = true
            tile.accessibilityTraits = .button
            tile.accessibilityLabel = Self.effectName(effect)
            tile.accessibilityIdentifier = "conversation.textEffects.\(effect.rawValue)"
            let label = ConversationEffectLabel()
            label.isUserInteractionEnabled = false
            label.effectSeed = ConversationTextEffectMotion.seed(effect.rawValue)
            tile.addSubview(label)
            tile.addAction(UIAction { [weak self] _ in self?.composer?.textView.toggle(effect) }, for: .touchUpInside)
            addSubview(tile)
            effectTiles.append((effect, tile, label))
        }
        refreshState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    /// "B", "I", "U", "S" drawn in their own style.
    private static func styleGlyph(_ style: ConversationTextStyle) -> NSAttributedString {
        let letter: String
        switch style {
        case .bold: letter = "B"
        case .italic: letter = "I"
        case .underline: letter = "U"
        default: letter = "S"
        }
        let base = UIFont.systemFont(ofSize: 19, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: ConversationRichTextStyler.font(base: base, size: 19, style: style.intersection([.bold, .italic])),
            .foregroundColor: UIColor.label,
        ]
        if style == .underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style == .strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: letter, attributes: attributes)
    }

    func refreshState() {
        guard let textView = composer?.textView else { return }
        let style = textView.activeStyle
        for (entry, button) in styleButtons {
            let on = style.contains(entry)
            button.backgroundColor = on ? UIColor.systemBackground : .clear
            button.isSelected = on
            button.accessibilityTraits = on ? [.button, .selected] : .button
        }
        let effect = textView.activeEffect
        for (entry, tile, _) in effectTiles {
            let on = entry == effect
            tile.layer.borderWidth = on ? 2 : 0
            tile.layer.borderColor = UIColor.systemBlue.resolvedColor(with: traitCollection).cgColor
            tile.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 16
        let width = bounds.width - 2 * inset
        titleLabel.frame = CGRect(x: inset + 40, y: 10, width: width - 80, height: 30)
        closeButton.frame = CGRect(x: bounds.width - inset - 30, y: 10, width: 30, height: 30)
        styleBar.frame = CGRect(x: inset, y: 50, width: width, height: 44)
        let segment = (styleBar.bounds.width - 8) / CGFloat(styleButtons.count)
        for (index, (_, button)) in styleButtons.enumerated() {
            button.frame = CGRect(x: 4 + CGFloat(index) * segment, y: 4, width: segment, height: 36)
        }
        let top: CGFloat = 104
        let bottom = bounds.height - max(safeAreaInsets.bottom, 8)
        let gap: CGFloat = 8
        let rows = CGFloat((effectTiles.count + 1) / 2)
        let tileHeight = max(36, floor((bottom - top - gap * (rows - 1)) / rows))
        let tileWidth = (width - gap) / 2
        for (index, (effect, tile, label)) in effectTiles.enumerated() {
            let column = CGFloat(index % 2)
            let row = CGFloat(index / 2)
            tile.frame = CGRect(x: inset + column * (tileWidth + gap), y: top + row * (tileHeight + gap), width: tileWidth, height: tileHeight)
            let text = NSMutableAttributedString(string: Self.effectName(effect), attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: UIColor.label,
            ])
            ConversationRichText.toggle(effect, in: NSRange(location: 0, length: text.length), of: text)
            ConversationRichTextStyler.applyDisplayAttributes(to: text, baseFont: .systemFont(ofSize: 17, weight: .medium), lineHeight: 24)
            let size = text.boundingRect(with: CGSize(width: tileWidth - 16, height: tileHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral.size
            label.attributedText = text
            label.frame = CGRect(x: (tileWidth - size.width) / 2, y: (tileHeight - size.height) / 2, width: size.width, height: size.height)
        }
    }
}
#endif
