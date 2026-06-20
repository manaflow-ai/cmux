import Bonsplit
import CmuxAppKitSupportUI
import CmuxSettings
import CmuxTerminal

extension DockSplitStore {
    func applyGhosttyChrome(from config: GhosttyConfig) {
        bonsplitController.configuration.appearance = Self.makeAppearance(from: config)
    }

    static func makeConfiguration() -> BonsplitConfiguration {
        let config = GhosttyConfig.load()
        return BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: !CloseTabWarningStore(defaults: .standard).hidesTabCloseButton,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            tabBarVisibility: .always,
            appearance: makeAppearance(from: config)
        )
    }

    static func makeAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        return BonsplitConfiguration.Appearance(
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight,
            tabTitleFontSize: config.surfaceTabBarFontSize,
            splitButtonBackdropEffect: Workspace.bonsplitSplitButtonBackdropEffect(),
            splitButtonTooltips: Workspace.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: Workspace.bonsplitChromeColors(
                backgroundColor: config.backgroundColor,
                backgroundOpacity: config.backgroundOpacity,
                sharesWindowBackdrop: sharesWindowBackdrop,
                renderingMode: renderingMode
            ),
            usesSharedBackdrop: sharesWindowBackdrop
        )
    }
}
