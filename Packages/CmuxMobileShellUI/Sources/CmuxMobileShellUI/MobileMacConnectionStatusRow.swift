import CmuxMobileShellModel
import SwiftUI

/// A workspace-list row that surfaces a problem connection state (reconnecting
/// or offline) above the workspaces, so the user can tell a healthy link from a
/// recovering or dropped one.
struct MobileMacConnectionStatusRow: View {
    let host: String
    let status: MobileMacConnectionStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(status.tintColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(host.isEmpty ? status.description : host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileMacConnectionStatus")
    }
}
