import Bonsplit
import CmuxAppKitSupportUI
import CmuxSettings
import CmuxTerminal
import CoreGraphics

extension DockSplitStore {
    /// Minimum Dock pane size (points) in either axis. Smaller than Bonsplit's
    /// 100pt default because the Dock is hosted in the narrow right sidebar.
    static let minimumDockPaneSize: CGFloat = 48

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
            // The Dock lives in the narrow right sidebar. Bonsplit's default
            // 100pt pane minimum leaves a side-by-side split almost no divider
            // travel in a ~220-300pt-wide sidebar (the divider clamps to roughly
            // 46-54%), which reads as "the divider is stuck". Use a small
            // sidebar-appropriate minimum so panes stay resizable in both
            // orientations while still keeping a usable floor.
            minimumPaneWidth: Self.minimumDockPaneSize,
            minimumPaneHeight: Self.minimumDockPaneSize,
            splitButtonBackdropEffect: Workspace.bonsplitSplitButtonBackdropEffect(),
            splitButtonTooltips: Workspace.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: Workspace.bonsplitChromeColors(
                backgroundColor: config.backgroundColor,
                backgroundOpacity: config.backgroundOpacity,
                sharesWindowBackdrop: sharesWindowBackdrop,
                renderingMode: renderingMode,
                paneBorderColorHex: PaneAppearanceSettings.paneBorderColorHex()
            ),
            usesSharedBackdrop: sharesWindowBackdrop
        )
    }
}
