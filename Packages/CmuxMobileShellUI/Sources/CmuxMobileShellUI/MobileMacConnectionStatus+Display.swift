import CmuxMobileShellModel
import CmuxMobileSupport
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
            return L10n.string("mobile.connection.unavailable", defaultValue: "Mac offline")
        }
    }

    var description: String {
        switch self {
        case .connected:
            return L10n.string("mobile.connection.connectedDescription", defaultValue: "Live terminal sync is active.")
        case .reconnecting:
            return L10n.string("mobile.connection.reconnectingDescription", defaultValue: "Trying to reach the Mac app.")
        case .unavailable:
            return L10n.string("mobile.connection.unavailableDescription", defaultValue: "Open cmux on the Mac or wake the computer.")
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
