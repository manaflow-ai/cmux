import SwiftUI

/// Workspace title button used by the Labs bottom-sheet switcher.
struct WorkspaceDetailTitleButton: View, Equatable {
    let titleValue: WorkspaceTitleMenuValue
    let action: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.titleValue == rhs.titleValue
    }

    var body: some View {
        Button(action: action) {
            WorkspaceTitleToolbarLabel(
                token: titleValue.labelToken,
                terminalTheme: titleValue.terminalTheme
            )
            .frame(
                minWidth: min(MobileLeadingToolbarTitleWidth.floor, cap),
                maxWidth: cap,
                alignment: .leading
            )
        }
        .accessibilityIdentifier("MobileWorkspaceTitleMenu")
    }

    private var cap: CGFloat {
        MobileLeadingToolbarTitleWidth(
            contentWidth: titleValue.contentWidth,
            hasBackButton: titleValue.hasBackButton,
            hasTrailingCluster: titleValue.hasTrailingCluster,
            hasChatToggle: titleValue.hasChatToggle
        ).cap
    }
}
