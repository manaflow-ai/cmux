#if canImport(UIKit)
import UIKit

/// Draws only line numbers whose TextKit 1 fragments intersect the viewport.
@MainActor
final class ChatArtifactLineNumberGutterView: UIView {
    weak var textView: UITextView?
    var lineIndex = ChatArtifactLineIndex()
    var textFontPointSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.45)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let textContainer = textView.textContainer
        let layoutManager = textView.layoutManager
        let visibleTextRect = CGRect(
            x: textView.contentOffset.x - textView.textContainerInset.left,
            y: textView.contentOffset.y - textView.textContainerInset.top,
            width: textView.bounds.width,
            height: textView.bounds.height
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleTextRect,
            in: textContainer
        )
        let font = UIFont.monospacedDigitSystemFont(
            ofSize: max(9, textFontPointSize * 0.78),
            weight: .regular
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.secondaryLabel,
            .paragraphStyle: paragraphStyle,
        ]

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] _, usedRect, _, fragmentGlyphRange, _ in
            guard let self else { return }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            let lineNumber = self.lineIndex.lineNumber(
                containingUTF16Offset: characterRange.location
            )
            guard self.lineIndex.offset(forLine: lineNumber) == characterRange.location else {
                return
            }
            let labelRect = CGRect(
                x: 4,
                y: usedRect.minY + textView.textContainerInset.top - textView.contentOffset.y,
                width: max(0, self.bounds.width - 12),
                height: max(usedRect.height, font.lineHeight)
            )
            String(lineNumber).draw(in: labelRect, withAttributes: attributes)
        }

        UIColor.separator.setFill()
        UIBezierPath(rect: CGRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height)).fill()
    }
}
#endif
