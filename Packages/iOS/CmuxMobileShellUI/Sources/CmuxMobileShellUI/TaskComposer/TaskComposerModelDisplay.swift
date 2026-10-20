#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

extension Array where Element == MobileTaskAgentModel {
    /// The selected model's display name, or the localized "Default"
    /// fallback shared by every model-picker treatment.
    func displayName(forSelected id: String?) -> String {
        guard let id else {
            return L10n.string(
                "mobile.taskComposer.model.default",
                defaultValue: "Default"
            )
        }
        return first { $0.id == id }?.displayName ?? id
    }
}

extension View {
    /// The model-picker accessibility triple shared by every treatment so the
    /// label, value, and hint copy cannot drift between variants.
    func taskComposerModelAccessibility(valueName: String) -> some View {
        accessibilityLabel(L10n.string("mobile.taskComposer.model", defaultValue: "Model"))
            .accessibilityValue(valueName)
            .accessibilityHint(L10n.string(
                "mobile.taskComposer.model.accessibilityHint",
                defaultValue: "Chooses the model this agent runs with."
            ))
    }
}
#endif
