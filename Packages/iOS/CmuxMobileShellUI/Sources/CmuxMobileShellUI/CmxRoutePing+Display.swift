#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Display derivations for a ``CmxRoutePingResult`` shown on the Computers
/// detail screen. The phrasing mirrors the pairing failure copy so a refused
/// ping reads the same as a refused pair ("cmux isn't listening").
extension CmxRoutePingResult {
    var pingLabel: String {
        switch self {
        case let .reachable(latencyMilliseconds):
            return String(
                format: L10n.string(
                    "mobile.computers.ping.reachableFormat",
                    defaultValue: "Reachable · %d ms"
                ),
                latencyMilliseconds
            )
        case .refused:
            return L10n.string(
                "mobile.computers.ping.refused",
                defaultValue: "Reachable, but cmux isn't listening"
            )
        case .unreachable:
            return L10n.string(
                "mobile.computers.ping.unreachable",
                defaultValue: "No route to host"
            )
        case .timedOut:
            return L10n.string(
                "mobile.computers.ping.timedOut",
                defaultValue: "Timed out"
            )
        case .dnsFailed:
            return L10n.string(
                "mobile.computers.ping.dnsFailed",
                defaultValue: "DNS lookup failed"
            )
        case .permissionDenied:
            return L10n.string(
                "mobile.computers.ping.permissionDenied",
                defaultValue: "Blocked by Local Network privacy"
            )
        case .failed:
            return L10n.string(
                "mobile.computers.ping.failed",
                defaultValue: "Unreachable"
            )
        case .unsupportedRoute:
            return L10n.string(
                "mobile.computers.ping.unsupported",
                defaultValue: "Not pingable"
            )
        }
    }

    var pingColor: Color {
        switch self {
        case .reachable:
            return .green
        case .refused, .permissionDenied:
            // The address answered; the listener/permission is the problem, not
            // reachability. Amber, not red.
            return .orange
        case .unreachable, .timedOut, .dnsFailed, .failed:
            return .red
        case .unsupportedRoute:
            return .secondary
        }
    }

    var pingSymbol: String {
        switch self {
        case .reachable:
            return "checkmark.circle.fill"
        case .refused, .permissionDenied:
            return "exclamationmark.circle.fill"
        case .unreachable, .timedOut, .dnsFailed, .failed:
            return "xmark.circle.fill"
        case .unsupportedRoute:
            return "minus.circle"
        }
    }
}
#endif
