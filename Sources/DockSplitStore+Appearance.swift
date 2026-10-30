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
        var appearance = Self.makeAppearance(from: config)
        appearance.splitButtons = bonsplitController.configuration.appearance.splitButtons
        bonsplitController.configuration.appearance = appearance
    }

    /// Applies Dock chrome using the window's already-resolved theme color.
    /// Bonsplit is an AppKit-hosted subtree, so it cannot safely infer the
    /// active cmux scheme from the ambient window appearance.
    func applyGhosttyChrome(
        from config: GhosttyConfig,
        windowAppearance: WindowAppearanceSnapshot
    ) {
        var appearance = Self.makeAppearance(
            from: config,
            windowAppearance: windowAppearance
        )
        appearance.splitButtons = bonsplitController.configuration.appearance.splitButtons
        bonsplitController.configuration.appearance = appearance
    }

    static func makeConfiguration() -> BonsplitConfiguration {
        let config = GhosttyConfig.loadForCmux()
        return BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: !CloseTabWarningStore(defaults: .standard).hidesTabCloseButton,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            tabBarVisibility: resolvedTabBarVisibility(),
            appearance: makeAppearance(from: config)
        )
    }

    /// Applies the same built-in surface-tab buttons used by workspace panes.
    /// The Dock has no workspace-command execution context, so custom command
    /// buttons remain workspace-only until Dock routing is added. Built-ins
    /// pass the same availability gate as the workspace bar, so a disabled
    /// browser draws no inert globe button here either (#10866).
    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String
    ) {
        let splitButtons = buttons.compactMap { button -> BonsplitConfiguration.SplitActionButton? in
            guard case .builtIn(let builtIn) = button.action,
                  builtIn.bonsplitAction != nil,
                  Workspace.surfaceTabBarBuiltInActionIsAvailable(builtIn) else { return nil }
            return button.bonsplitActionButton(
                configSourcePath: sourcePath,
                globalConfigPath: globalConfigPath
            )
        }
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtons != splitButtons else { return }
        configuration.appearance.splitButtons = splitButtons
        bonsplitController.configuration = configuration
    }

    /// Resolves the app-level `app.tabBarVisibility` setting to bonsplit's
    /// visibility mode.
    static func resolvedTabBarVisibility() -> TabBarVisibility {
        AppCatalogSection().tabBarVisibility.value(in: .standard).bonsplitVisibility
    }

    /// Re-resolves `app.tabBarVisibility` into this Dock's split controller so
    /// an open Dock picks up a settings change without a relaunch.
    func refreshTabBarVisibility() {
        let visibility = Self.resolvedTabBarVisibility()
        var configuration = bonsplitController.configuration
        guard configuration.tabBarVisibility != visibility else { return }
        configuration.tabBarVisibility = visibility
        bonsplitController.configuration = configuration
    }

    static func makeAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        makeAppearance(from: config, windowAppearance: nil)
    }

    /// Resolves Dock Bonsplit chrome against the mounted window backdrop when available.
    static func makeAppearance(
        from config: GhosttyConfig,
        windowAppearance: WindowAppearanceSnapshot?
    ) -> BonsplitConfiguration.Appearance {
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        let renderingMode = windowAppearance?.terminalRenderingMode
            ?? WindowAppearanceSnapshot.terminalRenderingMode(
                usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
            )
        // The controller is created before SwiftUI mounts the Dock view, so
        // there may not be a ``WindowAppearanceSnapshot`` yet. Resolve that
        // first configuration through the same terminal-theme authority as
        // the mounted path instead of letting Bonsplit fall back to the
        // host window's ambient appearance for one render pass.
        let chromeBackgroundColor = windowAppearance?.resolvedChromeBackgroundColor
            ?? Workspace.resolvedTerminalChromeBackgroundColor(
                backgroundColor: config.backgroundColor,
                backgroundOpacity: config.backgroundOpacity
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
            dividerHitExpansion: PortalSplitDividerRegion.dividerHitExpansion,
            splitButtonBackdropEffect: Workspace.bonsplitSplitButtonBackdropEffect(),
            splitButtonTooltips: Workspace.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: Workspace.bonsplitChromeColors(
                backgroundColor: config.backgroundColor,
                backgroundOpacity: config.backgroundOpacity,
                sharesWindowBackdrop: sharesWindowBackdrop,
                renderingMode: renderingMode,
                paneBorderColorHex: PaneChromeSettings.paneBorderColorHex(),
                splitDividerColor: config.splitDividerColor,
                chromeBackgroundColor: chromeBackgroundColor,
                chromeHost: windowAppearance == nil ? .workspace : .dock,
                increaseContrast: DisplayAccessibilityOptions.current.increaseContrast
            ),
            usesSharedBackdrop: sharesWindowBackdrop
        )
    }
}
