import SwiftUI
import Foundation
import AppKit
import CmuxFoundation
import Bonsplit
import CmuxCore
import CmuxWorkspaces
import CmuxTerminal

/// View shown for empty panes
struct EmptyPanelView: View {
    var workspace: Workspace
    let paneId: PaneID
    private let keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
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
        if let key = shortcut.keyEquivalent {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                emptyPaneActionButton(
                    title: "Terminal",
                    systemImage: "terminal.fill",
                    shortcut: newSurfaceShortcut,
                    action: createTerminal
                )

                emptyPaneActionButton(
                    title: "Browser",
                    systemImage: "globe",
                    shortcut: openBrowserShortcut,
                    action: createBrowser
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }
}
