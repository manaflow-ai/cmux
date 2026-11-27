#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// The label can update independently of the native menu's presentation.
struct TerminalPickerMenu: View {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    let terminalTheme: TerminalTheme

    var body: some View {
        Image(systemName: "rectangle.stack")
            .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            .overlay {
                TerminalPickerMenuButton(value: value, actions: actions)
            }
    }
}
#endif
