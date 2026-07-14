import SwiftUI

struct BrowserDesignModeToolbarButton: View {
    let controller: BrowserDesignModeController
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let inactiveColor: Color

    @State private var editorPresented = false

    var body: some View {
        Button {
            Task { @MainActor in
                if controller.isActive {
                    editorPresented = true
                } else {
                    let enabled = await controller.setEnabled(true, reason: "toolbar")
                    editorPresented = enabled && controller.isActive
                }
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
        .popover(isPresented: $editorPresented, arrowEdge: .bottom) {
            BrowserDesignModeEditor(controller: controller)
        }
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
        .onChange(of: controller.phase) { _, phase in
            if phase == .inactive { editorPresented = false }
        }
    }
}
