import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// One-tap previous and next terminal controls for the stepper Labs variant.
struct WorkspaceTerminalStepper: View, Equatable {
    let canStep: Bool
    let terminalTheme: TerminalTheme
    let selectPrevious: () -> Void
    let selectNext: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canStep == rhs.canStep && lhs.terminalTheme == rhs.terminalTheme
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: selectPrevious) {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel(L10n.string(
                "mobile.workspace.detail.previousTerminal",
                defaultValue: "Previous Terminal"
            ))
            .accessibilityIdentifier("MobileWorkspacePreviousTerminal")

            Button(action: selectNext) {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel(L10n.string(
                "mobile.workspace.detail.nextTerminal",
                defaultValue: "Next Terminal"
            ))
            .accessibilityIdentifier("MobileWorkspaceNextTerminal")
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .disabled(!canStep)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceTerminalStepper")
    }
}
