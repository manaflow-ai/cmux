import AppKit
import Bonsplit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var browserAvailable = BrowserAvailabilitySettings.isEnabled()

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .cmuxFont(size: 11, weight: .semibold, design: .rounded)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private func focusPane() {
        workspace.bonsplitController.focusPane(paneId)
    }

    private func createTerminal() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newTerminal pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newTerminalSurface(inPane: paneId, inheritWorkingDirectoryFallback: true)
    }

    private func createBrowser() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newBrowser pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newBrowserSurface(inPane: paneId)
    }

    private var newSurfaceShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .newSurface)
    }

    private var openBrowserShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openBrowser)
    }

    @ViewBuilder
    private func emptyPaneActionButton(
        title: String,
        systemImage: String,
        shortcut: StoredShortcut,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    // `.borderedProminent` paints its label in the system's
                    // on-accent text color, so bake that semantic color rather
                    // than a literal white.
                    CmuxSystemSymbolImage(
                        systemName: systemImage,
                        pointSize: 13,
                        tint: Color(nsColor: .alternateSelectedControlTextColor)
                    )
                    Text(title)
                }
                ShortcutHint(text: shortcut.displayString)
            }
        }
        .buttonStyle(.borderedProminent)

        if let key = shortcut.keyEquivalent {
            button.keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            button
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            CmuxSystemSymbolImage(magnified: "terminal.fill", pointSize: 48, tint: Color(nsColor: .tertiaryLabelColor))

            Text(String(localized: "emptyPanel.title", defaultValue: "Empty Panel"))
                .cmuxFont(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                emptyPaneActionButton(
                    title: String(localized: "emptyPanel.action.terminal", defaultValue: "Terminal"),
                    systemImage: "terminal.fill",
                    shortcut: newSurfaceShortcut,
                    action: createTerminal
                )

                if BrowserAvailabilitySettings.offersBrowserAffordance(isEnabled: browserAvailable) {
                    emptyPaneActionButton(
                        title: String(localized: "emptyPanel.action.browser", defaultValue: "Browser"),
                        systemImage: "globe",
                        shortcut: openBrowserShortcut,
                        action: createBrowser
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
        .trackingBrowserAffordanceAvailability($browserAvailable)
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }
}
