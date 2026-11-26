import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The shared empty state shown when an active filter hides every workspace,
/// with a one-tap way back to the full list. Takes the filter as a value plus a
/// reset closure so no observable state crosses a `List` boundary.
struct WorkspaceListFilterEmptyRow: View {
    let filter: MobileWorkspaceListFilter
    let showAll: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(filter.emptyStateText ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(L10n.string("mobile.workspaces.filter.showAll", defaultValue: "Show All")) {
                showAll()
            }
            .font(.subheadline)
            .accessibilityIdentifier("MobileWorkspaceFilterShowAll")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityIdentifier("MobileWorkspaceFilterEmpty")
    }
}
