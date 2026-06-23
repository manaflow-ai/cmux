import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A workspace-list row that surfaces a problem connection state (reconnecting
/// or offline) above the workspaces, so the user can tell a healthy link from a
/// recovering or dropped one.
struct MobileMacConnectionStatusRow: View {
    let host: String
    let status: MobileMacConnectionStatus
    var showsSpinner = false
    var titleOverride: String?
    var descriptionOverride: String?
    var retry: (() -> Void)?
    var addDevice: (() -> Void)?

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

            if retry != nil || addDevice != nil {
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
                            Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("MobileInitialConnectionAddDevice")
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: retry == nil && addDevice == nil ? .combine : .contain)
        .accessibilityIdentifier("MobileMacConnectionStatus")
    }
}
