#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
public import SwiftUI

/// The row that opens the Cloud section from the Computers screen.
///
/// HIG: Lists and tables (a disclosure row in an inset-grouped list) and
/// Navigation (pushes the section onto the host's stack). Rendered only when
/// a controller is in the environment.
public struct CloudEntryRow: View {
    @Environment(\.cloudSessionController) private var controller

    /// Creates the row.
    public init() {}

    public var body: some View {
        if let controller {
            NavigationLink(value: CloudSectionRoute()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("mobile.cloud.title", defaultValue: "Cloud"))
                        Text(L10n.string("mobile.cloud.entry.subtitle", defaultValue: "Terminals on your cloud machines, no VPN needed"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "cloud")
                }
            }
            .accessibilityIdentifier("MobileCloudEntryRow")
        }
    }
}
#endif
