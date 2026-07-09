import CmuxMobileSupport
import SwiftUI

struct WorkspaceGroupFooterRow: View {
    let groupName: String?

    var body: some View {
        // Invisible spacer row: keeps the end-of-group drop target and
        // accessibility element without drawing the old indent/corner marks.
        Color.clear
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
