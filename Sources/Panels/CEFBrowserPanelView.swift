import AppKit
import CmuxFoundation
import SwiftUI

struct CEFBrowserPanelView: View {
    @ObservedObject var panel: CEFBrowserPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var suggestions: BrowserPortalOmnibarSuggestionsConfiguration?
    @State private var visibilityOwnerID = UUID()
    @State private var chromeStyle: BrowserChromeStyle
    @State private var tabBarFontSize: CGFloat = GhosttyConfig.load(
        globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
    ).surfaceTabBarFontSize

    init(
        panel: CEFBrowserPanel,
        isFocused: Bool,
        isVisibleInUI: Bool,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.panel = panel
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        self.onRequestPanelFocus = onRequestPanelFocus
        self._chromeStyle = State(
            initialValue: BrowserChromeStyle.resolve(
                for: .light,
                themeBackgroundColor: GhosttyBackgroundTheme.currentColor(),
                drawsBackground: true
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            OmnibarPaneChrome(
                panel: panel,
                isFocused: isFocused,
                chromeStyle: chromeStyle,
                tabBarFontSize: tabBarFontSize,
                accessorySpacing: 2,
                onRequestPanelFocus: onRequestPanelFocus,
                onReloadOrStop: {
                    if panel.isLoading {
                        panel.stopLoading()
                    } else {
                        panel.reload()
                    }
                },
                onReload: panel.reload,
                onHardReload: nil,
                // OmnibarPaneChrome performs the engine-neutral exit handoff
                // through panel.performAddressBarExitFocusHandoff after commits.
                onAddressBarFocusStateChange: { _ in },
                onChromeHeightChange: { _ in },
                onSuggestionsPresentationChange: { configuration in
                    suggestions = configuration
                },
                leadingAccessories: {
                    EmptyView()
                },
                trailingAccessories: { _ in
                    CEFExtensionActionBar(
                        panel: panel,
                        isVisibleInUI: isVisibleInUI
                    )
                }
            )

            CEFBrowserHostRepresentable(
                hostView: panel.hostView,
                ownerID: visibilityOwnerID,
                suggestions: suggestions,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                panel.start(url: panel.currentURL)
            }
        }
        .background(Color(nsColor: chromeStyle.backgroundColor))
        .onAppear {
            panel.setVisibleInUI(isVisibleInUI, ownerID: visibilityOwnerID)
            refreshChromeStyle()
        }
        .onDisappear {
            panel.releaseVisibilityOwner(visibilityOwnerID)
        }
        .onChange(of: isVisibleInUI) { _, visible in
            panel.setVisibleInUI(visible, ownerID: visibilityOwnerID)
        }
        .onChange(of: colorScheme) { _, _ in
            refreshChromeStyle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            tabBarFontSize = GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).surfaceTabBarFontSize
        }
    }

    private func refreshChromeStyle() {
        chromeStyle = BrowserChromeStyle.resolve(
            for: colorScheme,
            themeBackgroundColor: GhosttyBackgroundTheme.currentColor(),
            drawsBackground: true
        )
    }
}
