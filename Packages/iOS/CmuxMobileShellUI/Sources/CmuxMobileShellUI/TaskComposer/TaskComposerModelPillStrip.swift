#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Horizontally scrolling one-tap model choices below the composer agent row.
struct TaskComposerModelPillStrip: View {
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isDisabled: Bool
    let selectModel: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                pill(
                    id: nil,
                    title: L10n.string(
                        "mobile.taskComposer.model.default",
                        defaultValue: "Default"
                    )
                )

                ForEach(models) { model in
                    pill(id: model.id, title: model.displayName)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(L10n.string("mobile.taskComposer.model", defaultValue: "Model"))
    }

    private func pill(id: String?, title: String) -> some View {
        let isSelected = selectedModelID == id
        return Button {
            selectModel(id)
        } label: {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(minHeight: 30)
                .background(
                    isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isSelected
                                ? Color.accentColor.opacity(0.65)
                                : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 1.25 : 1
                        )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(L10n.string(
            "mobile.taskComposer.model.accessibilityHint",
            defaultValue: "Chooses the model this agent runs with."
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("MobileTaskComposerModelPill-\(id ?? "default")")
    }
}
#endif
