import CmuxAgentChat
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An actionable multiple-choice question card: prompt plus one bordered
/// button per option. Once answered it freezes into a receipt line showing
/// the chosen option.
public struct ChatQuestionCardView: View {
    private let question: ChatQuestion
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Set on the first option tap so the buttons disarm immediately;
    /// answering is raw key injection over the Mac round-trip, and a second
    /// tap before the receipt echoes back would select a different option.
    @State private var tappedIndex: Int?

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
                    choose(index)
                } label: {
                    HStack(spacing: 6) {
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
                        if tappedIndex == index {
                            Spacer(minLength: 6)
                            ProgressView()
                                .controlSize(.small)
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
                .accessibilityIdentifier("ChatQuestionOption\(index)")
            }
        }
        .disabled(tappedIndex != nil)
        .opacity(tappedIndex == nil ? 1 : 0.6)
    }

    private func choose(_ index: Int) {
        guard tappedIndex == nil else { return }
        tappedIndex = index
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        actions.answerOption(index)
    }

    private func receipt(selected: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
            Text(selected)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
