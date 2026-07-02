import SwiftUI

@MainActor
struct SidebarWorkspaceCloseButtonSettingsRow: View {
    let model: DefaultsValueModel<Bool>

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.hideWorkspaceCloseButton"),
            String(localized: "settings.sidebar.hideWorkspaceCloseButton", defaultValue: "Hide Workspace Close Button"),
            subtitle: String(localized: "settings.sidebar.hideWorkspaceCloseButton.subtitle", defaultValue: "Hide the sidebar close button and let workspace titles use the reclaimed width.")
        ) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
