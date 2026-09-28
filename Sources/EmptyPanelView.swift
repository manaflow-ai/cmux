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
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var fontMagnificationPercent

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

    /// Reads the art and the terminal config off the main thread, then
    /// shows the art in the terminal's font, size and palette. A cleared
    /// setting or unusable file restores the default view.
    private func reloadCustomArt() async {
        let path = artFilePath
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            customArt = nil
            return
        }
        let colorScheme = GhosttyConfig.currentColorSchemePreference()
        let magnification = fontMagnificationPercent
        let content = await Task.detached(priority: .utility) {
            let loader = EmptyPaneArtLoader()
            return loader.art(atPath: path).map { art in
                loader.content(
                    for: art,
                    config: GhosttyConfig.loadForCmux(
                        preferredColorScheme: colorScheme,
                        globalFontMagnificationPercent: magnification
                    )
                )
            }
        }.value
        guard !Task.isCancelled else { return }
        customArt = content
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
        .task(id: ArtReloadTrigger(path: artFilePath, fontMagnificationPercent: fontMagnificationPercent)) { @MainActor in
            // Subscribe before the first load so a reload during it is not missed.
            let configReloads = NotificationCenter.default.notifications(named: .ghosttyConfigDidReload)
            await reloadCustomArt()
            for await _ in configReloads {
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

/// What the empty pane's art depends on besides config reloads.
private struct ArtReloadTrigger: Equatable {
    let path: String
    let fontMagnificationPercent: Int
}
