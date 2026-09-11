import AppKit
import SwiftUI

/// The sidebar footer's Cloud button, left of Help: opens the right sidebar's
/// Cloud tab through the same reveal path as the shortcut and the command
/// palette. The tab lists This Mac's workspaces ahead of every Cloud machine.
struct SidebarCloudButton: View {
    @ObservedObject var fileExplorerState: FileExplorerState
    private let title = String(localized: "rightSidebar.mode.machines", defaultValue: "Cloud")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            revealCloudTab()
        } label: {
            CmuxSystemSymbolImage(
                systemName: "cloud",
                pointSize: SidebarFooterButtonMetrics.cloudIconSize,
                weight: .medium,
                tint: .secondary
            )
            .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize)
        .background(TitlebarControlAnchorView { anchorView = $0 })
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SidebarCloudButton")
    }

    /// Mirrors `handleCommandPaletteRightSidebarMode`: reveal and focus the
    /// Cloud tab in this window, else switch the sidebar state directly.
    private func revealCloudTab() {
        let mode = RightSidebarMode.machines
        guard mode.isAvailable() else {
            NSSound.beep()
            return
        }
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: anchorView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        ) != true {
            fileExplorerState.setVisible(true)
            if fileExplorerState.mode != mode {
                fileExplorerState.mode = mode
            }
        }
    }
}
