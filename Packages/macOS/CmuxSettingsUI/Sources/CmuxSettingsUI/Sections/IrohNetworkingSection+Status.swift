import CMUXMobileCore
import SwiftUI

/// Localized status text and attention note for the host's broker lifecycle.
struct IrohNetworkingAttentionNote: View {
    let snapshot: CmxIrohSettingsSnapshot

    @ViewBuilder
    var body: some View {
        if snapshot.requiresReauthentication {
            SettingsCardNote(String(
                localized: "settings.networking.status.reauthenticationRequired.detail",
                defaultValue: "The broker rejected this Mac's session. Sign in again to restore iPhone connectivity."
            ))
        } else if !snapshot.staleRelayIDs.isEmpty || snapshot.failureDescription != nil {
            SettingsCardNote(String(
                localized: "settings.networking.attention",
                defaultValue: "Your saved relay choice needs attention. Direct Iroh remains available, but cmux will not substitute an unselected relay."
            ))
        }
    }
}

extension IrohNetworkingSection {
    static func networkingRuntimeStatusText(
        for snapshot: CmxIrohSettingsSnapshot
    ) -> String {
        if snapshot.requiresReauthentication {
            return String(
                localized: "settings.networking.status.reauthenticationRequired",
                defaultValue: "Sign in again to reconnect this Mac"
            )
        }
        return switch snapshot.runtimeStatus {
        case .inactive:
            String(localized: "settings.networking.status.inactive", defaultValue: "Inactive")
        case .starting:
            String(localized: "settings.networking.status.starting", defaultValue: "Starting")
        case .active:
            String(localized: "settings.networking.status.active", defaultValue: "Iroh endpoint active")
        case .direct:
            String(localized: "settings.networking.status.direct", defaultValue: "Connected directly peer-to-peer")
        case let .relayed(provider, region):
            String(localized: "settings.networking.status.relayed", defaultValue: "Connected through \(provider), \(region)")
        case let .privateNetwork(displayName):
            if displayName.isEmpty {
                String(
                    localized: "settings.networking.status.private.generic",
                    defaultValue: "Connected through a private network"
                )
            } else {
                String(
                    localized: "settings.networking.status.private",
                    defaultValue: "Connected through \(displayName)"
                )
            }
        case .degraded:
            String(localized: "settings.networking.status.degraded", defaultValue: "Direct-only until relay settings recover")
        }
    }
}
