#if os(iOS)
import UIKit

extension TranscriptRowLayout {
    static func proseAgent(
        _ source: String,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        builder: TranscriptAttributedTextBuilder
    ) -> TranscriptRowLayoutResult {
        let text = builder.make(
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
        attachmentCount: Int = 0,
        hasImage: Bool = false,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        builder: TranscriptAttributedTextBuilder
    ) -> TranscriptRowLayoutResult {
        let text = builder.make(
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
        let safeAttachmentCount = max(attachmentCount, hasImage ? 1 : 0)
        let showsAttachments = !leading && safeAttachmentCount > 0
        let attachmentText = builder.make(
            text: String(safeAttachmentCount),
            style: .metadataEmphasized,
            density: spacing.density
        )
        let attachmentTextSize = TranscriptTextMeasurer().measure(
            attachmentText,
            constrainedTo: maximumTextWidth,
            scale: scale,
            maximumNumberOfLines: 1,
            lineBreakMode: .byClipping
        ).size
        let attachmentChipWidth = showsAttachments
            ? 8 + 12 + 5 + attachmentTextSize.width + (hasImage ? 5 + 12 : 0) + 8
            : 0
        let bubbleWidth = leading
            ? maximumBubbleWidth
            : min(
                maximumBubbleWidth,
                pixelCeil(max(measurement.size.width, attachmentChipWidth) + 28, scale: scale)
            )
        let bubbleX = leading ? 24 : width - 24 - bubbleWidth
        let attachmentChipHeight: CGFloat = 18
        let attachmentExtraHeight = showsAttachments ? 8 + attachmentChipHeight : 0
        let bubbleFrame = CGRect(
            x: bubbleX,
            y: spacing.top,
            width: bubbleWidth,
            height: pixelCeil(measurement.size.height + 20 + attachmentExtraHeight, scale: scale)
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
        var texts = [TranscriptRowTextElement(
            attributedText: text,
            frame: textFrame,
            role: .foreground,
            alignment: .left,
            maximumNumberOfLines: 0
        )]
        var glyphs = [TranscriptRowGlyphElement]()
        if showsAttachments {
            let chipFrame = CGRect(
                x: bubbleFrame.minX + 14,
                y: textFrame.maxY + 8,
                width: attachmentChipWidth,
                height: attachmentChipHeight
            )
            backgrounds.append(TranscriptRowBackgroundElement(
                frame: chipFrame,
                kind: .attachmentChip,
                cornerRadius: attachmentChipHeight / 2
            ))
            let paperclipFrame = CGRect(
                x: chipFrame.minX + 8,
                y: chipFrame.minY + 3,
                width: 12,
                height: 12
            )
            glyphs.append(TranscriptRowGlyphElement(
                frame: paperclipFrame,
                systemName: "paperclip",
                pointSize: 9,
                weight: UIFont.Weight.regular.rawValue,
                role: .faint,
                isActivityIndicator: false
            ))
            let countFrame = CGRect(
                x: paperclipFrame.maxX + 5,
                y: chipFrame.minY + (chipFrame.height - attachmentTextSize.height) / 2,
                width: attachmentTextSize.width,
                height: attachmentTextSize.height
            )
            texts.append(TranscriptRowTextElement(
                attributedText: attachmentText,
                frame: countFrame,
                role: .dim,
                alignment: .left,
                maximumNumberOfLines: 1
            ))
            if hasImage {
                glyphs.append(TranscriptRowGlyphElement(
                    frame: CGRect(x: countFrame.maxX + 5, y: chipFrame.minY + 3, width: 12, height: 12),
                    systemName: "photo",
                    pointSize: 9,
                    weight: UIFont.Weight.regular.rawValue,
                    role: .faint,
                    isActivityIndicator: false
                ))
            }
        }
        return result(
            height: bubbleFrame.maxY + spacing.bottom,
            scale: scale,
            texts: texts,
            backgrounds: backgrounds,
            glyphs: glyphs
        )
    }
}
#endif
