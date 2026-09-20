import Foundation
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A workspace-list row that surfaces a problem connection state (reconnecting
/// or offline) above the workspaces, so the user can tell a healthy link from a
/// recovering or dropped one. A settled failure offers one explicit Retry action
/// and, when available, a link to the Mac setup guide.
struct MobileMacConnectionStatusRow: View {
    let host: String
    let status: MobileMacConnectionStatus
    var showsSpinner = false
    var titleOverride: String?
    var descriptionOverride: String?
    var retry: (() -> Void)?
    var addDevice: (() -> Void)?
    var setupGuideURL: URL?

    private var hasButtonActions: Bool {
        retry != nil || addDevice != nil
    }

    private var hasActions: Bool {
        hasButtonActions || setupGuideURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsSpinner || status == .reconnecting {
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

                    if let setupGuideURL {
                        Link(destination: setupGuideURL) {
                            Label(
                                L10n.string(
                                    "mobile.setupHelp.macAppGuideLink",
                                    defaultValue: "Mac setup guide"
                                ),
                                systemImage: "arrow.up.right.square"
                            )
                            .font(.callout.weight(.medium))
                        }
                        .accessibilityIdentifier("MobileMacSetupGuideLink")
                    }
                }

                Spacer(minLength: 8)
            }

            if hasButtonActions {
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
                            Text(L10n.string("mobile.connections.add", defaultValue: "Add Computer"))
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
        .accessibilityElement(children: hasActions ? .contain : .combine)
        .accessibilityIdentifier("MobileMacConnectionStatus")
    }
}
