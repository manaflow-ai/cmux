import SwiftUI

/// Displays the local runtime's safe diagnosis without adding it to exports.
struct IrohNetworkingAttentionNote: View {
    let failureDescription: String?
    let hasStaleRelayIDs: Bool

    var body: some View {
        if let failureDescription {
            SettingsCardNote(failureDescription)
        } else if hasStaleRelayIDs {
            SettingsCardNote(String(
                localized: "settings.networking.attention",
                defaultValue: "Your saved relay choice needs attention. Direct Iroh remains available, but cmux will not substitute an unselected relay."
            ))
        }
    }
}
