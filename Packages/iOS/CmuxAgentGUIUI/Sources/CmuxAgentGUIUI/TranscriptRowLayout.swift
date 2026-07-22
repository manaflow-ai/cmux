#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

struct TranscriptRowLayout: Sendable {
    static func layout(
        row: TranscriptRow,
        width: CGFloat,
        density: TranscriptDensity,
        scale: CGFloat,
        traitCollection: UITraitCollection? = nil
    ) -> TranscriptRowLayoutResult {
        let spacing = TranscriptRowSpacing.resolved(for: [row], density: density)[row.rowID]
            ?? TranscriptRowSpacing(top: 0, bottom: 0, density: density)
        return layout(
            row: row,
            width: width,
            spacing: spacing,
            scale: scale,
            askState: .idle,
            traitCollection: traitCollection
        )
    }

    static func layout(
        row: TranscriptRow,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        askState: TranscriptAskLayoutState,
        traitCollection: UITraitCollection? = nil
    ) -> TranscriptRowLayoutResult {
        let safeWidth = max(width, 1)
        let builder = TranscriptAttributedTextBuilder(traitCollection: traitCollection)
        switch row.rowKind {
        case .proseAgent(let text, _):
            return proseAgent(text, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .proseUser(let text, _, _, let attachmentCount, let hasImage):
            return bubble(
                text,
                pending: false,
                leading: false,
                attachmentCount: attachmentCount,
                hasImage: hasImage,
                width: safeWidth,
                spacing: spacing,
                scale: scale,
                builder: builder
            )
        case .status(let code, let detail):
            return metadata(
                [AgentGUIL10n.statusCode(code), detail].compactMap(\.self).joined(separator: " - "),
                width: safeWidth,
                spacing: spacing,
                scale: scale,
                builder: builder
            )
        case .dateHeader(let dayKey):
            return metadata(dayKey, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .boundary:
            return metadata(
                AgentGUIL10n.string(
                    "agent.transcript.boundary",
                    defaultValue: "Earlier history is on your Mac"
                ),
                width: safeWidth,
                spacing: spacing,
                scale: scale,
                builder: builder
            )
        case .hole:
            return metadata(
                AgentGUIL10n.hole(),
                width: safeWidth,
                spacing: spacing,
                scale: scale,
                builder: builder
            )
        case .pendingTicket(let ticket):
            return bubble(ticket.text, pending: true, leading: false, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .pendingAsk(let ask):
            return pendingAsk(
                ask,
                width: safeWidth,
                spacing: spacing,
                scale: scale,
                state: askState,
                builder: builder
            )
        case .streaming(let textTail):
            return bubble(textTail, pending: false, leading: true, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .genericActivity(let activity):
            return genericActivity(activity, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .activitySummary(let summary):
            return activitySummary(summary, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .activityItem(let item):
            return activityItem(item, width: safeWidth, spacing: spacing, scale: scale, builder: builder)
        case .unsupported(_, let summary):
            return genericActivity(
                TranscriptGenericActivity(kindLabel: "event", summary: summary),
                width: safeWidth,
                spacing: spacing,
                scale: scale,
                builder: builder
            )
        }
    }

    static func result(
        height: CGFloat,
        scale: CGFloat,
        texts: [TranscriptRowTextElement] = [],
        backgrounds: [TranscriptRowBackgroundElement] = [],
        glyphs: [TranscriptRowGlyphElement] = [],
        buttons: [TranscriptRowButtonElement] = []
    ) -> TranscriptRowLayoutResult {
        TranscriptRowLayoutResult(
            height: pixelCeil(max(height, 1), scale: scale),
            textElements: texts,
            backgroundElements: backgrounds,
            glyphElements: glyphs,
            buttonElements: buttons
        )
    }

    static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        ceil(value * max(scale, 1)) / max(scale, 1)
    }

    static func pixelFloor(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        floor(value * max(scale, 1)) / max(scale, 1)
    }
}
#endif
