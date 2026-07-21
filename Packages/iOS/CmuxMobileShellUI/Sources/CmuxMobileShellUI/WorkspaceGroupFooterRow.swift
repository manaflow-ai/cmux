import CmuxMobileSupport
import SwiftUI

struct WorkspaceGroupFooterRow: View {
    let groupName: String?
    let showsBoundary: Bool

    init(groupName: String?, showsBoundary: Bool = false) {
        self.groupName = groupName
        self.showsBoundary = showsBoundary
    }

    var body: some View {
        ZStack {
            Color.clear
            if showsBoundary {
                Capsule()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 2)
            }
        }
        .frame(height: 16)
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
