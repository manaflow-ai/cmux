import Foundation
import SwiftUI

/// Stateful host adapter around the data-only plugin management card.
@MainActor
struct PluginManagementSettingsCard: View {
    let hostActions: SettingsHostActions

    @State private var descriptors: [PluginManagementDescriptor]
    @State private var pendingApproval: PluginManagementDescriptor?
    @State private var showApprovalConfirmation = false

    init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _descriptors = State(initialValue: hostActions.pluginManagementDescriptors())
    }

    var body: some View {
        PluginManagementCard(
            descriptors: descriptors,
            approve: { pluginID in
                pendingApproval = descriptors.first { $0.id == pluginID }
                showApprovalConfirmation = pendingApproval != nil
            },
            setEnabled: { enabled, pluginID in
                hostActions.setPluginEnabled(enabled, pluginID: pluginID)
            }
        )
        .confirmationDialog(
            String(localized: "settings.plugins.review.title", defaultValue: "Enable plugin?"),
            isPresented: $showApprovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.plugins.review.approve", defaultValue: "Approve & Enable")) {
                if let plugin = pendingApproval {
                    hostActions.approveAndEnablePlugin(plugin.id)
                }
                pendingApproval = nil
            }
            Button(String(localized: "settings.plugins.review.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingApproval = nil
            }
        } message: {
            if let plugin = pendingApproval {
                Text(String.localizedStringWithFormat(
                    String(
                        localized: "settings.plugins.review.message",
                        defaultValue: "%@ requests: %@\n\nPlugins run as your macOS user and may access your files and network."
                    ),
                    plugin.displayName,
                    plugin.requestedCapabilities.joined(separator: ", ")
                ))
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .cmuxPluginManagementDidChange
            ) {
                guard !Task.isCancelled else { return }
                descriptors = hostActions.pluginManagementDescriptors()
            }
        }
    }
}
