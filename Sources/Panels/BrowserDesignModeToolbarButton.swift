import SwiftUI

struct BrowserDesignModeToolbarButton: View {
    let controller: BrowserDesignModeController
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let inactiveColor: Color
    let onToggle: @MainActor () async -> Bool

    var body: some View {
        Button {
            Task { @MainActor in
                guard await onToggle() else { return }
            }
        } label: {
            CmuxSystemSymbolImage(
                systemName: controller.isActive ? "paintbrush.pointed.fill" : "paintbrush.pointed",
                pointSize: iconPointSize,
                weight: .medium
            )
            .foregroundStyle(controller.isActive ? Color.accentColor : inactiveColor)
            .frame(width: hitSize, height: hitSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: hitSize, height: hitSize, alignment: .center)
        .disabled(!controller.canToggle)
        .opacity(controller.canToggle ? 1 : 0.4)
        .safeHelp(
            controller.unavailableMessage ?? String(
                format: String(
                    localized: "browser.designMode.buttonHelpFormat",
                    defaultValue: "Design Mode (%@)"
                ),
                KeyboardShortcutSettings.shortcut(for: .toggleBrowserDesignMode).displayString
            )
        )
        .accessibilityIdentifier("BrowserDesignModeButton")
    }
}
