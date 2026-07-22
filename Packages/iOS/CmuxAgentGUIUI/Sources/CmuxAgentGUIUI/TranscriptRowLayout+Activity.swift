#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

extension TranscriptRowLayout {
    static func genericActivity(
        _ activity: TranscriptGenericActivity,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        builder: TranscriptAttributedTextBuilder
    ) -> TranscriptRowLayoutResult {
        let register = TranscriptRowSpacing.register(for: spacing.density)
        let kindText = builder.make(
            text: AgentGUIL10n.activityKind(activity.kindLabel),
            style: .metadataEmphasized,
            density: spacing.density
        )
        let summaryText = builder.make(
            text: activity.summary,
            style: .metadata,
            density: spacing.density
        )
        let measurer = TranscriptTextMeasurer()
        let railWidth = max(width - 36, 1)
        let kindSize = measurer.measure(
            kindText,
            constrainedTo: railWidth,
            scale: scale,
            maximumNumberOfLines: 1,
            lineBreakMode: .byTruncatingTail
        ).size
        let summaryX = 18 + 17 + 8 + kindSize.width + 8
        let summaryWidth = max(width - 18 - summaryX, 1)
        let summarySize = measurer.measure(
            summaryText,
            constrainedTo: summaryWidth,
            scale: scale,
            maximumNumberOfLines: 1,
            lineBreakMode: .byTruncatingTail
        ).size
        let summaryHeight = min(summarySize.height, kindSize.height)
        let lineHeight = max(17, kindSize.height, summaryHeight)
        let lineY = spacing.top + register.activityVerticalPadding
        let glyphFrame = CGRect(x: 18, y: lineY + (lineHeight - 17) / 2, width: 17, height: 17)
        let kindFrame = CGRect(
            x: glyphFrame.maxX + 8,
            y: lineY + (lineHeight - kindSize.height) / 2,
            width: kindSize.width,
            height: kindSize.height
        )
        let summaryFrame = CGRect(
            x: summaryX,
            y: lineY + (lineHeight - summaryHeight) / 2,
            width: summaryWidth,
            height: summaryHeight
        )
        return result(
            height: lineY + lineHeight + register.activityVerticalPadding + spacing.bottom,
            scale: scale,
            texts: [
                TranscriptRowTextElement(
                    attributedText: kindText,
                    frame: kindFrame,
                    role: .foreground,
                    alignment: .left,
                    maximumNumberOfLines: 1
                ),
                TranscriptRowTextElement(
                    attributedText: summaryText,
                    frame: summaryFrame,
                    role: .dim,
                    alignment: .left,
                    maximumNumberOfLines: 1
                ),
            ],
            glyphs: [TranscriptRowGlyphElement(
                frame: glyphFrame,
                systemName: genericActivitySymbol(activity.kindLabel),
                pointSize: 13,
                weight: UIFont.Weight.regular.rawValue,
                role: .faint,
                isActivityIndicator: false
            )]
        )
    }

    static func activityItem(
        _ item: TranscriptActivityItem,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        builder: TranscriptAttributedTextBuilder
    ) -> TranscriptRowLayoutResult {
        let register = TranscriptRowSpacing.register(for: spacing.density)
        let kindText = builder.make(
            text: AgentGUIL10n.activityKind(item.kind),
            style: .metadataEmphasized,
            density: spacing.density
        )
        let summaryText = builder.make(
            text: AgentGUIL10n.activityDetail(item),
            style: .metadata,
            density: spacing.density
        )
        let measurer = TranscriptTextMeasurer()
        let railWidth = max(width - 48, 1)
        let kindSize = measurer.measure(
            kindText,
            constrainedTo: railWidth,
            scale: scale,
            maximumNumberOfLines: 1,
            lineBreakMode: .byTruncatingTail
        ).size
        let summaryX = 24 + 12 + 7 + kindSize.width + 7
        let summaryWidth = max(width - 24 - summaryX, 1)
        let lineHeight = register.activityItemHeight
        let lineY = spacing.top
        let kindHeight = min(kindSize.height, lineHeight)
        let kindFrame = CGRect(
            x: 24 + 12 + 7,
            y: lineY + (lineHeight - kindHeight) / 2,
            width: kindSize.width,
            height: kindHeight
        )
        let summarySize = measurer.measure(
            summaryText,
            constrainedTo: summaryWidth,
            scale: scale,
            maximumNumberOfLines: 1,
            lineBreakMode: .byTruncatingTail
        ).size
        let summaryHeight = min(summarySize.height, lineHeight)
        let summaryFrame = CGRect(
            x: summaryX,
            y: lineY + (lineHeight - summaryHeight) / 2,
            width: summaryWidth,
            height: summaryHeight
        )
        return result(
            height: lineY + lineHeight + spacing.bottom,
            scale: scale,
            texts: [
                TranscriptRowTextElement(
                    attributedText: kindText,
                    frame: kindFrame,
                    role: item.isFailed ? .error : .dim,
                    alignment: .left,
                    maximumNumberOfLines: 1
                ),
                TranscriptRowTextElement(
                    attributedText: summaryText,
                    frame: summaryFrame,
                    role: item.isFailed ? .error : .faint,
                    alignment: .left,
                    maximumNumberOfLines: 1
                ),
            ],
            glyphs: [TranscriptRowGlyphElement(
                frame: CGRect(x: 24, y: lineY + (lineHeight - 12) / 2, width: 12, height: 12),
                systemName: item.isFailed ? "exclamationmark.circle.fill" : activitySymbol(item.kind),
                pointSize: 9,
                weight: UIFont.Weight.regular.rawValue,
                role: item.isFailed ? .error : (item.isRunning ? .accent : .faint),
                isActivityIndicator: item.isRunning && !item.isFailed
            )]
        )
    }

    static func activitySummary(
        _ summary: TranscriptActivitySummary,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        builder: TranscriptAttributedTextBuilder
    ) -> TranscriptRowLayoutResult {
        let register = TranscriptRowSpacing.register(for: spacing.density)
        let label = AgentGUIL10n.activitySummary(summary)
        let text = builder.make(
            text: label,
            style: .metadata,
            density: spacing.density
        )
        let textWidth = max(width - 24 - 12 - 7 - 24, 1)
        let textHeight = min(
            TranscriptTextMeasurer().measure(
                text,
                constrainedTo: textWidth,
                scale: scale,
                maximumNumberOfLines: 1,
                lineBreakMode: .byTruncatingTail
            ).size.height,
            register.activitySummaryMinimumHeight
        )
        let rowHeight = register.activitySummaryMinimumHeight
        let rowY = spacing.top
        let glyphFrame = CGRect(
            x: 24,
            y: rowY + (rowHeight - 12) / 2,
            width: 12,
            height: 12
        )
        let textFrame = CGRect(
            x: glyphFrame.maxX + 7,
            y: rowY + (rowHeight - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        return result(
            height: rowY + rowHeight + spacing.bottom,
            scale: scale,
            texts: [TranscriptRowTextElement(
                attributedText: text,
                frame: textFrame,
                role: summary.failedCount > 0 ? .error : .faint,
                alignment: .left,
                maximumNumberOfLines: 1
            )],
            glyphs: [TranscriptRowGlyphElement(
                frame: glyphFrame,
                systemName: "chevron.right",
                pointSize: 9,
                weight: UIFont.Weight.semibold.rawValue,
                role: summary.failedCount > 0 ? .error : .faint,
                isActivityIndicator: false
            )],
            buttons: [TranscriptRowButtonElement(
                frame: CGRect(x: 24, y: rowY, width: max(width - 48, 1), height: rowHeight),
                title: nil,
                kind: .showActivity,
                isEnabled: true,
                accessibilityIdentifier: nil,
                accessibilityLabel: label,
                accessibilityHint: AgentGUIL10n.string(
                    "agent.activity.openHint",
                    defaultValue: "Opens activity details"
                )
            )]
        )
    }

    private static func genericActivitySymbol(_ kind: String) -> String {
        switch kind.lowercased() {
        case "command": "terminal"
        case "file": "doc.text"
        case "question": "questionmark.circle"
        case "permission": "hand.raised"
        case "thought": "brain"
        default: "sparkle.magnifyingglass"
        }
    }

    private static func activitySymbol(_ kind: TranscriptActivityKind) -> String {
        switch kind {
        case .assistant: "text.bubble"
        case .thought: "brain"
        case .command: "terminal"
        case .tool: "wrench.and.screwdriver"
        case .file: "doc.text"
        case .question: "questionmark.circle"
        case .permission: "hand.raised"
        case .status: "info.circle"
        case .attachment: "paperclip"
        case .unknown: "sparkle.magnifyingglass"
        }
    }
}
#endif
