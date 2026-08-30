import SwiftUI

extension MobileSection {
    @ViewBuilder
    func irohStatusRow(_ snapshot: MobilePairingStatusSnapshot) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:irohStatus",
            String(localized: "settings.mobile.iroh.status", defaultValue: "Iroh Endpoint"),
            subtitle: irohStatusSubtitle(snapshot)
        ) {
            Label(
                irohStatusText(snapshot),
                systemImage: irohStatusSymbol(snapshot)
            )
            .foregroundStyle(irohStatusColor(snapshot))
            .cmuxFont(.caption)
        }
    }

    func irohStatusText(_ snapshot: MobilePairingStatusSnapshot) -> String {
        switch snapshot.irohStatus {
        case .inactive:
            String(localized: "settings.mobile.iroh.status.inactive", defaultValue: "Inactive")
        case .starting:
            String(localized: "settings.mobile.iroh.status.starting", defaultValue: "Starting")
        case .active:
            String(localized: "settings.mobile.iroh.status.active", defaultValue: "Active")
        case .retrying:
            String(localized: "settings.mobile.iroh.status.retrying", defaultValue: "Retrying")
        case .failed:
            String(localized: "settings.mobile.iroh.status.failed", defaultValue: "Unavailable")
        case .reauthenticationRequired:
            String(localized: "settings.mobile.iroh.status.reauth", defaultValue: "Sign in again")
        }
    }

    func irohStatusSubtitle(_ snapshot: MobilePairingStatusSnapshot) -> String {
        switch snapshot.irohStatus {
        case .reauthenticationRequired:
            String(
                localized: "settings.mobile.iroh.status.reauth.subtitle",
                defaultValue: "The broker rejected this Mac's session. Sign in again to make it visible on iPhone."
            )
        case .retrying:
            if let operation = snapshot.irohBrokerOperation {
                return String(
                    format: String(
                        localized: "settings.mobile.iroh.status.retrying.subtitle",
                        defaultValue: "The %@ operation is temporarily unavailable; cmux will retry with backoff."
                    ),
                    operation
                )
            }
            return String(
                localized: "settings.mobile.iroh.status.retrying.subtitle.generic",
                defaultValue: "The broker is temporarily unavailable; cmux will retry with backoff."
            )
        case .failed:
            String(
                localized: "settings.mobile.iroh.status.failed.subtitle",
                defaultValue: "The endpoint stopped after a non-retryable broker error."
            )
        default:
            String(
                localized: "settings.mobile.iroh.status.subtitle",
                defaultValue: "Authenticated endpoint used by iPhone connections."
            )
        }
    }

    func irohStatusSymbol(_ snapshot: MobilePairingStatusSnapshot) -> String {
        switch snapshot.irohStatus {
        case .active: "checkmark.circle.fill"
        case .reauthenticationRequired: "person.crop.circle.badge.exclamationmark"
        case .retrying, .starting: "arrow.triangle.2.circlepath"
        case .failed: "xmark.circle.fill"
        case .inactive: "minus.circle"
        }
    }

    func irohStatusColor(_ snapshot: MobilePairingStatusSnapshot) -> Color {
        switch snapshot.irohStatus {
        case .active: .secondary
        case .reauthenticationRequired: .orange
        case .retrying, .starting: .secondary
        case .failed: .red
        case .inactive: .secondary
        }
    }
}
