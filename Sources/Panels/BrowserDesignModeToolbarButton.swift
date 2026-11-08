import CmuxFoundation
import SwiftUI

struct BrowserDesignModeToolbarButton: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
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
                weight: .medium,
                tint: controller.isActive ? cmuxAccent.color : inactiveColor
            )
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
