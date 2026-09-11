import Foundation
import SwiftUI

/// Automation card for reviewing and enabling user-installed plugins.
@MainActor
struct PluginManagementCard: View {
    let descriptors: [PluginManagementDescriptor]
    let approve: (String) -> Void
    let setEnabled: (Bool, String) -> Void

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.plugins.title", defaultValue: "Plugins"),
                subtitle: String(localized: "settings.plugins.subtitle", defaultValue: "Review user-installed plugins and their permissions.")
            ) {
                EmptyView()
            }
            ForEach(descriptors) { descriptor in
                let status = descriptor.isEnabled
                    ? String(localized: "settings.plugins.enabled", defaultValue: "Enabled")
                    : String(localized: "settings.plugins.disabled", defaultValue: "Disabled")
                let requestSummary = descriptor.requestedCapabilities.isEmpty
                    ? status
                    : String.localizedStringWithFormat(
                        String(
                            localized: "settings.plugins.requests",
                            defaultValue: "%@ · Requests: %@"
                        ),
                        status,
                        descriptor.requestedCapabilities.joined(separator: ", ")
                    )
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    descriptor.displayName,
                    subtitle: descriptor.loadError
                        ?? requestSummary
                ) {
                    if descriptor.needsApproval {
                        Button(String(localized: "settings.plugins.approve", defaultValue: "Review & Enable")) {
                            approve(descriptor.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if descriptor.canManage {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { descriptor.isEnabled },
                                set: { setEnabled($0, descriptor.id) }
                            )
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel(
                            String(localized: "settings.plugins.toggleLabel", defaultValue: "Enable plugin")
                        )
                    } else if descriptor.loadError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                }
            }
            if descriptors.isEmpty {
                SettingsCardDivider()
                SettingsCardNote(String(localized: "settings.plugins.empty", defaultValue: "No plugins found in the cmux plugin directory."))
            }
        }
    }
}
