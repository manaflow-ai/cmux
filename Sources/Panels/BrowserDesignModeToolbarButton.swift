import SwiftUI

struct BrowserDesignModeToolbarButton: View {
    let controller: BrowserDesignModeController
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let inactiveColor: Color

    var body: some View {
        Button {
            Task { @MainActor in
                await controller.toggle(reason: "toolbar")
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
        .disabled(controller.phase == .activating || controller.phase == .deactivating)
        .safeHelp(
            String(
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
