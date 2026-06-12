import CmuxAgentChat
import SwiftUI

/// An actionable multiple-choice question card: prompt plus one bordered
/// button per option. Once answered it freezes into a receipt line showing
/// the chosen option.
public struct ChatQuestionCardView: View {
    private let question: ChatQuestion
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Creates a question card.
    ///
    /// - Parameters:
    ///   - question: The question payload (pending or answered).
    ///   - actions: Row action bundle.
    public init(question: ChatQuestion, actions: ChatRowActions) {
        self.question = question
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(question.prompt)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let selected = question.selectedOptionLabel {
                    receipt(selected: selected)
                } else {
                    optionButtons
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.accent, lineWidth: 1.5)
            )
            Spacer(minLength: 32)
        }
    }

    private var optionButtons: some View {
        VStack(spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    actions.answerOption(index)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(theme.hairline, lineWidth: 1)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func receipt(selected: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
            Text(selected)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
