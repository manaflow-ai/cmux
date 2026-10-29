#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// A full-width, accessible choice row for the question answer sheet.
struct AgentFeedQuestionOptionRow: View {
    let question: MobileAgentFeedQuestion
    let option: MobileAgentFeedQuestionOption
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    AgentFeedMarkdownText(markdown: option.label, font: .subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                    if let description = option.description, !description.isEmpty {
                        AgentFeedMarkdownText(markdown: description, font: .footnote, color: .secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.13)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.52) : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            "MobileAgentFeedQuestionOption-\(question.id)-\(option.id)"
        )
    }

    private var symbolName: String {
        if question.multiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }
}
#endif
