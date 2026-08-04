import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Labs overflow that keeps secondary surface tools away from the title switcher.
struct WorkspaceDetailOverflowMenu: View, Equatable {
    let terminalValue: TerminalPickerMenuValue
    let terminalActions: TerminalPickerMenuActions
    let workspaceValue: WorkspaceTitleMenuContentValue
    let workspaceActions: WorkspaceTitleMenuActions
    let terminalTheme: TerminalTheme

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.terminalValue == rhs.terminalValue
            && lhs.workspaceValue == rhs.workspaceValue
            && lhs.terminalTheme == rhs.terminalTheme
    }

    var body: some View {
        Menu {
            TerminalPickerMenuContent(
                value: terminalValue,
                actions: terminalActions,
                mode: .utilitiesOnly
            )
            WorkspaceTitleMenuContent(
                value: workspaceValue,
                actions: workspaceActions
            )
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(L10n.string(
            "mobile.workspace.detail.moreActions",
            defaultValue: "More Workspace Actions"
        ))
        .accessibilityIdentifier("MobileWorkspaceLabOverflowMenu")
    }
}
