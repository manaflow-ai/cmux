#if os(iOS)
import UIKit

extension TranscriptRowLayout {
    static func metadata(
        _ label: String,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat
    ) -> TranscriptRowLayoutResult {
        let register = TranscriptRowSpacing.register(for: spacing.density)
        let text = TranscriptAttributedTextBuilder().make(
            text: label,
            style: .metadata,
            density: spacing.density
        )
        let textWidth = max(width - 40, 1)
        let measurement = TranscriptTextMeasurer().measure(text, constrainedTo: textWidth, scale: scale)
        let textFrame = CGRect(
            x: 20,
            y: spacing.top + register.metadataVerticalPadding,
            width: textWidth,
            height: measurement.size.height
        )
        return result(
            height: textFrame.maxY + register.metadataVerticalPadding + spacing.bottom,
            scale: scale,
            texts: [TranscriptRowTextElement(
                attributedText: text,
                frame: textFrame,
                role: .faint,
                alignment: .center,
                maximumNumberOfLines: 0
            )]
        )
    }
}
#endif
