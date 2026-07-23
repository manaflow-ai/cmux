import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileTerminal
import Foundation
import SwiftUI

/// Snapshot-isolated switcher for terminals, chat, local browser, and streamed Mac browsers.
struct TerminalPickerMenu: View, Equatable {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    let terminalTheme: TerminalTheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSwitcherPresented = false
    @State private var switcherPresentationID = UUID()
    @State private var compactDetent = PresentationDetent.fraction(0.72)
    #if DEBUG
    private let diagnostics = TerminalPickerMenuDiagnostics()
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value && lhs.terminalTheme == rhs.terminalTheme
    }

    var body: some View {
        Button {
            #if DEBUG
            diagnostics.recordContentBuilderEvaluation(rowCount: value.destinations.count)
            #endif
            actions.preparePresentation()
            switcherPresentationID = UUID()
            isSwitcherPresented = true
        } label: {
            Label(activeSurfaceName, systemImage: "rectangle.stack")
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(L10n.string("mobile.surfaceSwitcher.title", defaultValue: "Switch Tab"))
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(activeSurfaceName)
        .popover(isPresented: $isSwitcherPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            SurfaceSwitcherSheet(
                presentationID: switcherPresentationID,
                value: value,
                actions: actions,
                terminalTheme: terminalTheme,
                dismiss: dismiss
            )
            .id(switcherPresentationID)
            .frame(
                width: horizontalSizeClass == .regular
                    ? SurfaceSwitcherMetrics.regularPopoverWidth
                    : nil
            )
            .frame(maxHeight: SurfaceSwitcherMetrics.regularPopoverMaxHeight)
            .preferredColorScheme(terminalTheme.terminalColorScheme)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.fraction(0.72), .large], selection: $compactDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.disabled)
        }
    }

    private var activeSurfaceName: String {
        value.activeDestination?.title
            ?? value.selectedName
            ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal")
    }

    private func dismiss() {
        isSwitcherPresented = false
    }
}
