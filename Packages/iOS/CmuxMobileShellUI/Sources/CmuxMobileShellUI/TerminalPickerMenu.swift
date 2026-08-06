import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Snapshot-isolated native menu for switching the active workspace surface.
struct TerminalPickerMenu: View, Equatable {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    let terminalTheme: TerminalTheme
    #if DEBUG
    private let diagnostics = TerminalPickerMenuDiagnostics()
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value && lhs.terminalTheme == rhs.terminalTheme
    }

    var body: some View {
        Menu {
            instrumentedMenuContent
        } label: {
            Label(
                value.selectedName ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "rectangle.stack"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(value.selectedName ?? "")
    }

    @ViewBuilder
    private var instrumentedMenuContent: some View {
        #if DEBUG
        let _ = diagnostics.recordContentBuilderEvaluation(rowCount: value.rows.count)
        #endif
        TerminalPickerMenuContent(value: value, actions: actions)
    }
}
