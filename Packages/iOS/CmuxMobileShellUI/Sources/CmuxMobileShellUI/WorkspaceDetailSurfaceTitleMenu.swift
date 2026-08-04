import SwiftUI

/// Labs title control that can expose terminal content and workspace actions in one menu.
struct WorkspaceDetailSurfaceTitleMenu: View, Equatable {
    enum LabelStyle: Equatable {
        case workspaceFirst
        case terminalFirst
    }

    let titleValue: WorkspaceTitleMenuValue
    let terminalValue: TerminalPickerMenuValue
    let terminalActions: TerminalPickerMenuActions
    let workspaceValue: WorkspaceTitleMenuContentValue
    let workspaceActions: WorkspaceTitleMenuActions
    let mode: TerminalPickerMenuContent.Mode
    let includesWorkspaceActions: Bool
    let labelStyle: LabelStyle

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.titleValue == rhs.titleValue
            && lhs.terminalValue == rhs.terminalValue
            && lhs.workspaceValue == rhs.workspaceValue
            && lhs.mode == rhs.mode
            && lhs.includesWorkspaceActions == rhs.includesWorkspaceActions
            && lhs.labelStyle == rhs.labelStyle
    }

    var body: some View {
        Menu {
            TerminalPickerMenuContent(
                value: terminalValue,
                actions: terminalActions,
                mode: mode
            )
            if includesWorkspaceActions {
                WorkspaceTitleMenuContent(
                    value: workspaceValue,
                    actions: workspaceActions
                )
            }
        } label: {
            fittedLabel
        }
        .accessibilityIdentifier("MobileWorkspaceTitleMenu")
    }

    private var fittedLabel: some View {
        let cap = MobileLeadingToolbarTitleWidth(
            contentWidth: titleValue.contentWidth,
            hasBackButton: titleValue.hasBackButton,
            hasTrailingCluster: titleValue.hasTrailingCluster,
            hasChatToggle: titleValue.hasChatToggle
        ).cap

        return Group {
            switch labelStyle {
            case .workspaceFirst:
                WorkspaceTitleToolbarLabel(
                    token: titleValue.labelToken,
                    terminalTheme: titleValue.terminalTheme
                )
            case .terminalFirst:
                WorkspaceTerminalFirstToolbarLabel(
                    token: titleValue.labelToken,
                    terminalTheme: titleValue.terminalTheme
                )
            }
        }
        .frame(
            minWidth: min(MobileLeadingToolbarTitleWidth.floor, cap),
            maxWidth: cap,
            alignment: .leading
        )
    }
}
