#if os(iOS)
import SwiftUI

struct AgentFeedQuestionCustomAnswerRow: View {
    let questionID: String
    let multiSelect: Bool
    let isSelected: Bool
    @Binding var text: String
    var focusedQuestionID: FocusState<String?>.Binding
    let select: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button {
                select()
                focusedQuestionID.wrappedValue = questionID
            } label: {
                Image(systemName: symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(
                localized: "mobile.agentFeed.question.otherPlaceholder",
                defaultValue: "Your answer",
                bundle: .module
            )))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("MobileAgentFeedQuestionOther-\(questionID)")

            TextField(String(
                localized: "mobile.agentFeed.question.otherPlaceholder",
                defaultValue: "Your answer",
                bundle: .module
            ), text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...4)
            .focused(focusedQuestionID, equals: questionID)
            .padding(.vertical, 10)
            .padding(.trailing, 12)
            .accessibilityIdentifier("MobileAgentFeedQuestionText-\(questionID)")
        }
        .frame(minHeight: 44)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.52) : Color.clear,
                    lineWidth: 1
                )
        }
    }

    private var symbolName: String {
        if multiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }
}
#endif
