import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Display-only derivations of ``MobileMacConnectionStatus`` used by the
/// workspace list status row and the terminal status pill.
extension MobileMacConnectionStatus {
    var label: String {
        switch self {
        case .connected:
            return L10n.string("mobile.connection.connected", defaultValue: "Connected")
        case .reconnecting:
            return L10n.string("mobile.connection.reconnecting", defaultValue: "Reconnecting")
        case .unavailable:
            // The phone's live stream to the Mac is down. Don't assert the Mac
            // itself is offline (it usually isn't): say what we actually know.
            return L10n.string("mobile.connection.unavailable", defaultValue: "Disconnected")
        }
    }

    var description: String {
        switch self {
        case .connected:
            return L10n.string("mobile.connection.connectedDescription", defaultValue: "Live terminal sync is active.")
        case .reconnecting:
            return L10n.string("mobile.connection.reconnectingDescription", defaultValue: "Trying to reach the selected cmux build.")
        case .unavailable:
            return L10n.string("mobile.connection.unavailableDescription", defaultValue: "The live connection dropped. The selected cmux build may still be online. Tap Reconnect.")
        }
    }

    func description(transportKind: CmxAttachTransportKind?) -> String {
        guard let transportKind else { return description }
        let label = transportKind.mobileDisplayLabel
        switch self {
        case .connected:
            let format = L10n.string(
                "mobile.connection.connectedViaFormat",
                defaultValue: "Live terminal sync is active over %@."
            )
            return String(format: format, label)
        case .reconnecting:
            let format = L10n.string(
                "mobile.connection.reconnectingViaFormat",
                defaultValue: "Trying to restore the %@ connection."
            )
            return String(format: format, label)
        case .unavailable:
            let format = L10n.string(
                "mobile.connection.unavailableViaFormat",
                defaultValue: "The %@ connection dropped. Tap Reconnect."
            )
            return String(format: format, label)
        }
    }

    var symbolName: String {
        switch self {
        case .connected:
            return "checkmark.circle.fill"
        case .reconnecting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .unavailable:
            return "exclamationmark.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .connected:
            return .green
        case .reconnecting:
            return .orange
        case .unavailable:
            return .red
        }
    }
}
