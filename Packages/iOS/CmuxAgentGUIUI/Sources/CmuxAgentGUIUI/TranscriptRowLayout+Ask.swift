#if os(iOS)
import CmuxAgentReplica
import UIKit

extension TranscriptRowLayout {
    static func pendingAsk(
        _ ask: PendingAsk,
        width: CGFloat,
        spacing: TranscriptRowSpacing,
        scale: CGFloat,
        state: TranscriptAskLayoutState
    ) -> TranscriptRowLayoutResult {
        let builder = TranscriptAttributedTextBuilder()
        let measurer = TranscriptTextMeasurer()
        let cardFrameX: CGFloat = 18
        let innerX: CGFloat = 42
        let innerWidth = max(width - 84, 1)
        var y = spacing.top + 12
        var texts: [TranscriptRowTextElement] = []
        var glyphs: [TranscriptRowGlyphElement] = []
        var buttons: [TranscriptRowButtonElement] = []

        let prompt = builder.make(text: ask.promptSummary, style: .askPrompt, density: spacing.density)
        let promptWidth = max(innerWidth - 26, 1)
        let promptSize = measurer.measure(prompt, constrainedTo: promptWidth, scale: scale).size
        let promptHeight = max(promptSize.height, 18)
        glyphs.append(TranscriptRowGlyphElement(
            frame: CGRect(x: innerX, y: y + (promptHeight - 18) / 2, width: 18, height: 18),
            systemName: ask.kind == .permission ? "hand.raised" : "questionmark.circle",
            pointSize: 15,
            weight: UIFont.Weight.regular.rawValue,
            role: .faint,
            isActivityIndicator: false
        ))
        texts.append(TranscriptRowTextElement(
            attributedText: prompt,
            frame: CGRect(x: innerX + 26, y: y, width: promptWidth, height: promptHeight),
            role: .foreground,
            alignment: .left,
            maximumNumberOfLines: 0
        ))
        y += promptHeight

        if ask.options.isEmpty {
            y += 10
            let required = builder.make(
                text: AgentGUIL10n.string(
                    "agent.ask.terminalRequired",
                    defaultValue: "Answer this request in Terminal."
                ),
                style: .metadata,
                density: spacing.density
            )
            let requiredSize = measurer.measure(required, constrainedTo: innerWidth, scale: scale).size
            texts.append(TranscriptRowTextElement(
                attributedText: required,
                frame: CGRect(x: innerX, y: y, width: innerWidth, height: requiredSize.height),
                role: .dim,
                alignment: .left,
                maximumNumberOfLines: 0
            ))
            y += requiredSize.height + 10
            buttons.append(terminalButton(frame: CGRect(x: innerX, y: y, width: innerWidth, height: 36)))
            y += 36
        } else {
            for (index, option) in ask.options.enumerated() {
                y += 10
                let optionText = builder.make(text: option, style: .body, density: spacing.density)
                let optionSize = measurer.measure(optionText, constrainedTo: max(innerWidth - 24, 1), scale: scale).size
                let buttonHeight = max(36, pixelCeil(optionSize.height + 14, scale: scale))
                buttons.append(TranscriptRowButtonElement(
                    frame: CGRect(x: innerX, y: y, width: innerWidth, height: buttonHeight),
                    title: option,
                    kind: .askOption(index),
                    isEnabled: !state.isAnswering,
                    accessibilityIdentifier: "AgentAskOption-\(index)",
                    accessibilityLabel: nil,
                    accessibilityHint: nil
                ))
                y += buttonHeight
            }
        }

        if state.hasFailed {
            y += 10
            let failed = builder.make(
                text: AgentGUIL10n.string(
                    "agent.ask.failed",
                    defaultValue: "The answer could not be sent. Try again or use Terminal."
                ),
                style: .askError,
                density: spacing.density
            )
            let failedSize = measurer.measure(failed, constrainedTo: innerWidth, scale: scale).size
            texts.append(TranscriptRowTextElement(
                attributedText: failed,
                frame: CGRect(x: innerX, y: y, width: innerWidth, height: failedSize.height),
                role: .error,
                alignment: .left,
                maximumNumberOfLines: 0
            ))
            y += failedSize.height + 10
            buttons.append(terminalButton(frame: CGRect(x: innerX, y: y, width: innerWidth, height: 36)))
            y += 36
        }

        let cardFrame = CGRect(
            x: cardFrameX,
            y: spacing.top,
            width: max(width - 36, 1),
            height: y + 12 - spacing.top
        )
        return result(
            height: cardFrame.maxY + spacing.bottom,
            scale: scale,
            texts: texts,
            backgrounds: [TranscriptRowBackgroundElement(
                frame: cardFrame,
                kind: .askCard,
                cornerRadius: 14
            )],
            glyphs: glyphs,
            buttons: buttons
        )
    }

    private static func terminalButton(frame: CGRect) -> TranscriptRowButtonElement {
        TranscriptRowButtonElement(
            frame: frame,
            title: AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"),
            kind: .showTerminal,
            isEnabled: true,
            accessibilityIdentifier: "AgentAskShowTerminal",
            accessibilityLabel: nil,
            accessibilityHint: nil
        )
    }
}
#endif
