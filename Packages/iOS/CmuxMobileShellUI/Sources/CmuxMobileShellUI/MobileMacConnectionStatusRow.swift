import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A workspace-list row that surfaces a problem connection state (reconnecting
/// or offline) above the workspaces, so the user can tell a healthy link from a
/// recovering or dropped one. When offline and a `reconnect` action is provided,
/// it offers an explicit Reconnect button so a returning user whose auto-
/// reconnect failed is never stranded on a list with no way to act (the
/// integrated list stays the only surface, no separate picker screen).
struct MobileMacConnectionStatusRow: View {
    let host: String
    let status: MobileMacConnectionStatus
    var showsSpinner = false
    var titleOverride: String?
    var descriptionOverride: String?
    var retry: (() -> Void)?
    var addDevice: (() -> Void)?
    /// Manual reconnect for the offline (`.unavailable`) state. `nil` in previews
    /// and where reconnect is not applicable.
    var reconnect: (() -> Void)?

    private var hasActions: Bool {
        retry != nil || addDevice != nil || (status == .unavailable && reconnect != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: status.symbolName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(status.tintColor)
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleOverride ?? status.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(descriptionOverride ?? (host.isEmpty ? status.description : host))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            if hasActions {
                HStack(spacing: 10) {
                    if let retry {
                        Button(action: retry) {
                            Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("MobileInitialConnectionRetry")
                    }

                    if let addDevice {
                        Button(action: addDevice) {
                            Text(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("MobileInitialConnectionAddDevice")
                    }

                    if status == .unavailable, let reconnect {
                        Button(action: reconnect) {
                            Text(L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("MobileMacReconnectButton")
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: hasActions ? .contain : .combine)
        .accessibilityIdentifier("MobileMacConnectionStatus")
    }
}
