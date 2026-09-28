import AppKit
import Bonsplit
import CmuxFoundation
import CmuxSettings
import CmuxTerminalCore
import SwiftUI

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var browserAvailable = BrowserAvailabilitySettings.isEnabled()
    @AppStorage(EmptyPaneCatalogSection().artFile.userDefaultsKey) private var artFilePath = ""
    @State private var customArt: EmptyPaneArtView.Content?

    /// Space kept below the art for the action buttons and around the edges.
    private static let artReservedHeight: CGFloat = 100
    private static let artHorizontalInset: CGFloat = 48

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

    /// Reads the art off the main thread, then pairs it with the terminal's
    /// current font and palette. A cleared setting or unusable file restores
    /// the default view.
    private func reloadCustomArt() async {
        let path = artFilePath
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            customArt = nil
            return
        }
        let loader = EmptyPaneArtLoader()
        let art = await Task.detached(priority: .utility) { loader.art(atPath: path) }.value
        guard !Task.isCancelled else { return }
        customArt = art.map { loader.content(for: $0, config: GhosttyConfig.loadForCmux()) }
    }

    var body: some View {
        Group {
            if let customArt {
                GeometryReader { proxy in
                    VStack(spacing: 16) {
                        EmptyPaneArtView(
                            content: customArt,
                            maxSize: CGSize(
                                width: proxy.size.width - Self.artHorizontalInset,
                                height: proxy.size.height - Self.artReservedHeight
                            )
                        )
                        actionButtons
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                VStack(spacing: 16) {
                    CmuxSystemSymbolImage(magnified: "terminal.fill", pointSize: 48, tint: Color(nsColor: .tertiaryLabelColor))

                    Text(String(localized: "emptyPanel.title", defaultValue: "Empty Panel"))
                        .cmuxFont(.headline)
                        .foregroundStyle(.secondary)

                    actionButtons
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
        .trackingBrowserAffordanceAvailability($browserAvailable)
        // Re-read on setting changes and on config reloads (`cmux reload-config`,
        // theme switches), which also pick up edits to the art file itself.
        .task(id: artFilePath) { @MainActor in
            await reloadCustomArt()
            for await _ in NotificationCenter.default.notifications(named: .ghosttyConfigDidReload) {
                await reloadCustomArt()
            }
        }
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }

    private var actionButtons: some View {
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
}
