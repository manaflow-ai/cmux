#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Shared inline model picker used by the menu-based composer variants.
struct TaskComposerModelMenuContent: View {
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let selectModel: (String?) -> Void

    var body: some View {
        Picker(
            L10n.string("mobile.taskComposer.model", defaultValue: "Model"),
            selection: Binding(
                get: { selectedModelID },
                set: { id in
                    guard id == nil || models.contains(where: { $0.id == id }) else { return }
                    selectModel(id)
                }
            )
        ) {
            Text(L10n.string(
                "mobile.taskComposer.model.default",
                defaultValue: "Default"
            ))
            .tag(String?.none)

            ForEach(models) { model in
                Text(verbatim: model.displayName)
                    .tag(Optional(model.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityIdentifier("MobileTaskComposerModelPicker")
    }
}
#endif
