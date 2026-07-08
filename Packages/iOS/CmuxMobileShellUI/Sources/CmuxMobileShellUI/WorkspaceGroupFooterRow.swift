import CmuxMobileSupport
import SwiftUI

struct WorkspaceGroupFooterRow: View {
    let groupName: String?

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 1)
                .padding(.leading, 7)

            Rectangle()
                .fill(Color.secondary.opacity(0.42))
                .frame(width: 14, height: 1)
                .padding(.leading, 7)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(footerAccessibilityLabel)
        .accessibilityHint(
            L10n.string(
                "mobile.workspaceGroup.footer.a11y.hint",
                defaultValue: "Drop above to add to the group, or below to place this workspace at the top level."
            )
        )
    }

    private var footerAccessibilityLabel: String {
        let format = L10n.string(
            "mobile.workspaceGroup.footer.a11y.label",
            defaultValue: "End of %@"
        )
        let localizedGroupName = groupName ?? L10n.string(
            "mobile.workspaceGroup.footer.a11y.fallback",
            defaultValue: "group"
        )
        return String(format: format, localizedGroupName)
    }
}
