import CmuxMobileSupport
import SwiftUI

struct WorkspaceGroupFooterRow: View {
    let groupName: String?

    var body: some View {
        // Invisible spacer row: the end-of-group drop slot (before it = into
        // the group, after it = root) and accessibility element, drawing
        // nothing. 16pt keeps the slot draggable without a visible gap; only
        // populated expanded groups emit it, so header stacks stay slot-free.
        Color.clear
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
