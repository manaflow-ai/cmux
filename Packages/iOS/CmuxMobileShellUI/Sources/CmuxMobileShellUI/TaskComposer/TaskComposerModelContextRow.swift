#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Model menu styled like the route rows in the composer context card.
struct TaskComposerModelContextRow: View {
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isDisabled: Bool
    let selectModel: (String?) -> Void

    var body: some View {
        ZStack {
            TaskComposerRouteLabel(
                icon: .symbol("cpu"),
                title: L10n.string("mobile.taskComposer.model", defaultValue: "Model"),
                value: selectedModelName,
                valueFont: .caption.weight(.semibold),
                valueTruncationMode: .tail,
                chevronSystemName: "chevron.up.chevron.down"
            )
            .accessibilityHidden(true)

            Menu {
                TaskComposerModelMenuContent(
                    models: models,
                    selectedModelID: selectedModelID,
                    selectModel: selectModel
                )
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(10)
        .disabled(isDisabled)
        .taskComposerModelAccessibility(valueName: selectedModelName)
        .accessibilityIdentifier("MobileTaskComposerModelContextRow")
    }

    private var selectedModelName: String {
        models.displayName(forSelected: selectedModelID)
    }
}
#endif
