#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// A label whose text-effect glyphs (drawn clear by the label) are drawn and
/// looped by a `ConversationTextEffectLayer` riding on its layer, so they
/// follow every move, scale and snapshot of the label.
final class ConversationEffectLabel: UILabel {
    private let effectLayer = ConversationTextEffectLayer()
    /// Keys explode and jitter randomness to the message.
    var effectSeed: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(effectLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var attributedText: NSAttributedString? {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshEffects(restart: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refreshEffects(restart: false) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshEffects(restart: true)
        }
    }

    @objc private func reduceMotionChanged() {
        refreshEffects(restart: true)
    }

    private func refreshEffects(restart: Bool) {
        effectLayer.frame = bounds
        guard let text = attributedText, text.length > 0, bounds.width > 0 else {
            effectLayer.clear()
            return
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        // Effect glyphs render from their dynamic colors resolved for this
        // appearance, which also keys the shared rendering cache (a row
        // scrolling back in, or rendered ahead by the transcript's prefetch,
        // reuses its glyphs).
        let hasEffects = ConversationRichTextStyler.hasEffects(text)
        let input = hasEffects ? text.resolvingDynamicColors(with: traitCollection) : text
        traitCollection.performAsCurrent {
            effectLayer.update(
                text: input,
                textSize: bounds.size,
                scale: max(1, scale),
                animated: !UIAccessibility.isReduceMotionEnabled,
                seed: effectSeed,
                restart: restart,
                cacheToken: hasEffects ? Self.resolvedCacheToken : nil
            )
        }
    }

    /// Cache token for text whose colors are already resolved.
    nonisolated static let resolvedCacheToken = "resolved"
}

extension NSAttributedString {
    /// A copy with every dynamic color attribute resolved for `traits`, so
    /// the string draws the same on any thread.
    func resolvingDynamicColors(with traits: UITraitCollection) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: self)
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
            for (key, value) in attributes {
                guard let color = value as? UIColor else { continue }
                result.addAttribute(key, value: color.resolvedColor(with: traits), range: range)
            }
        }
        return result
    }
}
#endif
