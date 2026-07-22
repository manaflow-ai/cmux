#if os(iOS)
import Foundation
import UIKit

struct TranscriptTextMeasurer {
    init() {}

    func measure(
        _ text: TranscriptAttributedText,
        constrainedTo proposedWidth: CGFloat,
        scale: CGFloat
    ) -> TranscriptTextMeasurement {
        let width = max(proposedWidth, 1)
        let textStorage = NSTextStorage(attributedString: text.value)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        configure(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let fallbackHeight = (text.value.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.lineHeight ?? 0
        let measuredHeight = max(used.maxY, text.value.length == 0 ? fallbackHeight : 0)
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

    @MainActor func configure(_ textView: UITextView) {
        _ = textView.layoutManager
        textView.textContainerInset = .zero
        configure(textView.textContainer)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = [.link]
        textView.clipsToBounds = true
    }

    private func configure(_ textContainer: NSTextContainer) {
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.maximumNumberOfLines = 0
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
