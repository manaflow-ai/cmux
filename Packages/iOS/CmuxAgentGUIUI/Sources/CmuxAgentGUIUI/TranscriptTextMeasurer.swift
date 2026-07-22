#if os(iOS)
import Foundation
import UIKit

struct TranscriptTextMeasurer: Sendable {
    init() {}

    func measure(
        _ text: TranscriptAttributedText,
        constrainedTo proposedWidth: CGFloat,
        scale: CGFloat,
        maximumNumberOfLines: Int = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> TranscriptTextMeasurement {
        let width = max(proposedWidth, 1)
        let textStorage = NSTextStorage(attributedString: text.value)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        configure(
            textContainer,
            maximumNumberOfLines: maximumNumberOfLines,
            lineBreakMode: lineBreakMode
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let fallbackHeight = text.value.length > 0
            ? (text.value.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.lineHeight ?? 0
            : 0
        let measuredHeight = max(used.maxY, fallbackHeight)
        let size = CGSize(
            width: pixelCeiled(min(width, max(used.maxX, 1)), scale: scale),
            height: pixelCeiled(max(measuredHeight, 1), scale: scale)
        )
        var codeBlockFrames: [CGRect] = []
        text.value.enumerateAttribute(
            .transcriptCodeBlock,
            in: NSRange(location: 0, length: text.value.length)
        ) { value, characterRange, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            codeBlockFrames.append(CGRect(
                x: 0,
                y: pixelFloored(glyphBounds.minY - 2, scale: scale),
                width: pixelCeiled(width, scale: scale),
                height: pixelCeiled(glyphBounds.height + 4, scale: scale)
            ))
        }
        return TranscriptTextMeasurement(size: size, codeBlockFrames: codeBlockFrames)
    }

    // UITextView mutation is UIKit view work; the TextKit measurement path above remains nonisolated.
    @MainActor func configure(_ textView: UITextView) {
        _ = textView.layoutManager
        textView.textContainerInset = .zero
        configure(textView.textContainer)
        textView.contentInset = .zero
        textView.contentOffset = .zero
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsHorizontalScrollIndicator = false
        textView.showsVerticalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = [.link]
        textView.clipsToBounds = true
    }

    private func configure(
        _ textContainer: NSTextContainer,
        maximumNumberOfLines: Int = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) {
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = lineBreakMode
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
    }

    private func pixelCeiled(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        ceil(value * max(scale, 1)) / max(scale, 1)
    }

    private func pixelFloored(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        floor(value * max(scale, 1)) / max(scale, 1)
    }
}
#endif
