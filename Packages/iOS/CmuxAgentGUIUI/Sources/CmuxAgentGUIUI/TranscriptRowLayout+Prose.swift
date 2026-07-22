#if os(iOS)
import UIKit

extension TranscriptRowLayout {
    static func proseAgent(
        _ source: String,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat
    ) -> TranscriptRowLayoutResult {
        let text = TranscriptAttributedTextBuilder().make(
            text: source,
            style: .agentMarkdown,
            density: spacing.density
        )
        let textWidth = max(width - 48, 1)
        let measurement = TranscriptTextMeasurer().measure(text, constrainedTo: textWidth, scale: scale)
        let textFrame = CGRect(x: 24, y: spacing.top, width: textWidth, height: measurement.size.height)
        let codeBackgrounds = measurement.codeBlockFrames.map {
            TranscriptRowBackgroundElement(
                frame: $0.offsetBy(dx: textFrame.minX, dy: textFrame.minY),
                kind: .codeBlock,
                cornerRadius: 6
            )
        }
        return result(
            height: textFrame.maxY + spacing.bottom,
            scale: scale,
            texts: [TranscriptRowTextElement(
                attributedText: text,
                frame: textFrame,
                role: .foreground,
                alignment: .left,
                maximumNumberOfLines: 0
            )],
            backgrounds: codeBackgrounds
        )
    }

    static func bubble(
        _ source: String,
        pending: Bool,
        leading: Bool,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat
    ) -> TranscriptRowLayoutResult {
        let text = TranscriptAttributedTextBuilder().make(
            text: source,
            style: leading ? .agentMarkdown : .body,
            density: spacing.density
        )
        let railWidth = max(width - 48, 1)
        let maximumBubbleWidth = leading
            ? railWidth
            : max(1, pixelFloor(railWidth * 0.85, scale: scale))
        let maximumTextWidth = max(maximumBubbleWidth - 28, 1)
        let measurement = TranscriptTextMeasurer().measure(
            text,
            constrainedTo: maximumTextWidth,
            scale: scale
        )
        let bubbleWidth = leading
            ? maximumBubbleWidth
            : min(maximumBubbleWidth, pixelCeil(measurement.size.width + 28, scale: scale))
        let bubbleX = leading ? 24 : width - 24 - bubbleWidth
        let bubbleFrame = CGRect(
            x: bubbleX,
            y: spacing.top,
            width: bubbleWidth,
            height: pixelCeil(measurement.size.height + 20, scale: scale)
        )
        let textFrame = CGRect(
            x: bubbleFrame.minX + 14,
            y: bubbleFrame.minY + 10,
            width: max(bubbleFrame.width - 28, 1),
            height: measurement.size.height
        )
        var backgrounds: [TranscriptRowBackgroundElement]
        if leading {
            backgrounds = measurement.codeBlockFrames.map {
                TranscriptRowBackgroundElement(
                    frame: $0.offsetBy(dx: textFrame.minX, dy: textFrame.minY),
                    kind: .codeBlock,
                    cornerRadius: 6
                )
            }
        } else {
            backgrounds = [TranscriptRowBackgroundElement(
                frame: bubbleFrame,
                kind: pending ? .pendingBubble : .userBubble,
                cornerRadius: 14
            )]
        }
        return result(
            height: bubbleFrame.maxY + spacing.bottom,
            scale: scale,
            texts: [TranscriptRowTextElement(
                attributedText: text,
                frame: textFrame,
                role: .foreground,
                alignment: .left,
                maximumNumberOfLines: 0
            )],
            backgrounds: backgrounds
        )
    }
}
#endif
