import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Bonsplit chrome and appearance
extension Workspace {
    private static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip("New Browser"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            tabTitleFontSize: config.surfaceTabBarFontSize
        )
    }

    nonisolated static func usesSharedSurfaceBackdrop(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "sidebarMatchTerminalBackground")
    }

    nonisolated static func usesWindowRootTerminalBackdrop() -> Bool {
        true
    }

    nonisolated static func bonsplitChromeHex(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false
    ) -> String {
        _ = sharesWindowBackdrop
        let themedColor = WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func usesBonsplitPaneTerminalBackdrop(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        sharesWindowBackdrop: Bool
    ) -> Bool {
        // The window root backdrop owns terminal fills. Bonsplit pane fills
        // would add a second translucent layer under the Metal surface.
        return false
    }

    nonisolated static func bonsplitChromeColors(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        let surfaceHex = bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let borderHex = WindowChromeSeparatorColor
            .color(forChromeBackground: backgroundColor)
            .hexString(includeAlpha: true)

        if sharesWindowBackdrop {
            return .init(
                backgroundHex: surfaceHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            )
        }

        let paneBackgroundHex = usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
            ? surfaceHex
            : "#00000000"
        return .init(
            backgroundHex: surfaceHex,
            tabBarBackgroundHex: surfaceHex,
            splitButtonBackdropHex: surfaceHex,
            paneBackgroundHex: paneBackgroundHex,
            borderHex: borderHex
        )
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        // Keep this signature aligned with bonsplitChromeHex for settings tests
        // and future background-image handling.
        let backgroundHex = backgroundColor.hexString()
        let borderHex = WindowChromeSeparatorColor
            .color(forChromeBackground: backgroundColor)
            .hexString(includeAlpha: true)

        if sharesWindowBackdrop {
            return .init(
                backgroundHex: backgroundHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            )
        }

        let paneBackgroundHex = usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
            ? backgroundHex
            : "#00000000"
        return .init(
            backgroundHex: backgroundHex,
            tabBarBackgroundHex: backgroundHex,
            splitButtonBackdropHex: backgroundHex,
            paneBackgroundHex: paneBackgroundHex,
            borderHex: borderHex
        )
    }

    private static func bonsplitChromeColorsEqual(
        _ lhs: BonsplitConfiguration.Appearance.ChromeColors,
        _ rhs: BonsplitConfiguration.Appearance.ChromeColors
    ) -> Bool {
        lhs.backgroundHex == rhs.backgroundHex &&
            lhs.tabBarBackgroundHex == rhs.tabBarBackgroundHex &&
            lhs.splitButtonBackdropHex == rhs.splitButtonBackdropHex &&
            lhs.paneBackgroundHex == rhs.paneBackgroundHex &&
            lhs.borderHex == rhs.borderHex
    }

    private static func bonsplitChromeColorsLogDescription(
        _ colors: BonsplitConfiguration.Appearance.ChromeColors
    ) -> String {
        "bg=\(colors.backgroundHex ?? "nil") " +
            "tabBarBg=\(colors.tabBarBackgroundHex ?? "nil") " +
            "splitBackdrop=\(colors.splitButtonBackdropHex ?? "nil") " +
            "paneBg=\(colors.paneBackgroundHex ?? "nil") " +
            "border=\(colors.borderHex ?? "nil")"
    }

    static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double,
        tabTitleFontSize: CGFloat = 11
    ) -> BonsplitConfiguration.Appearance {
        let sharesWindowBackdrop = usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let chromeColors = Self.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        return BonsplitConfiguration.Appearance(
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight,
            tabTitleFontSize: tabTitleFontSize,
            splitButtonBackdropEffect: Self.bonsplitSplitButtonBackdropEffect(),
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: chromeColors,
            usesSharedBackdrop: sharesWindowBackdrop
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = Self.bonsplitChromeColors(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        let nextTabTitleFontSize = config.surfaceTabBarFontSize
        let currentAppearance = bonsplitController.configuration.appearance
        let currentTabTitleFontSize = currentAppearance.tabTitleFontSize
        let colorsChanged = !Self.bonsplitChromeColorsEqual(
            currentAppearance.chromeColors,
            nextChromeColors
        )
        let sharedBackdropChanged = currentAppearance.usesSharedBackdrop != sharesWindowBackdrop
        let fontSizeChanged = abs(currentTabTitleFontSize - nextTabTitleFontSize) > 0.0001
        let isNoOp = !colorsChanged && !sharedBackdropChanged && !fontSizeChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentAppearance.chromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "currentTabFont=\(String(format: "%.3f", currentTabTitleFontSize)) " +
                "nextTabFont=\(String(format: "%.3f", nextTabTitleFontSize)) " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentAppearance.usesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        guard !isNoOp else { return }

        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = sharesWindowBackdrop
        }
        if fontSizeChanged {
            bonsplitController.configuration.appearance.tabTitleFontSize = nextTabTitleFontSize
        }

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0) " +
                "resultingTabFont=\(String(format: "%.3f", bonsplitController.configuration.appearance.tabTitleFontSize))"
            )
        }
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = Self.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let currentUsesSharedBackdrop = bonsplitController.configuration.appearance.usesSharedBackdrop
        let colorsChanged = !Self.bonsplitChromeColorsEqual(currentChromeColors, nextChromeColors)
        let sharedBackdropChanged = currentUsesSharedBackdrop != sharesWindowBackdrop
        let isNoOp = !colorsChanged && !sharedBackdropChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentChromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentUsesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = sharesWindowBackdrop
        }
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0)"
            )
        }
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    func refreshSplitButtonBackdropEffect() {
        var configuration = bonsplitController.configuration
        configuration.appearance.splitButtonBackdropEffect = Self.bonsplitSplitButtonBackdropEffect()
        bonsplitController.configuration = configuration
    }

    func refreshTabCloseButtonVisibility() {
        let allowCloseTabs = !CloseTabWarningSettings.hidesTabCloseButton()
        var configuration = bonsplitController.configuration
        guard configuration.allowCloseTabs != allowCloseTabs else { return }
        configuration.allowCloseTabs = allowCloseTabs
        bonsplitController.configuration = configuration
    }

    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) {
        let executableButtons = Dictionary(
            uniqueKeysWithValues: buttons.compactMap { button in
                if button.terminalCommand != nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: button.actionSourcePath ?? terminalCommandSourcePaths[button.id]
                        )
                    )
                }
                if let workspaceCommand = workspaceCommands[button.id] {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: workspaceCommand,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                if case .builtIn(let builtInAction) = button.action,
                   builtInAction.bonsplitAction == nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: builtInAction,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                return nil
            }
        )
        surfaceTabBarCommandButtons = executableButtons
        surfaceTabBarButtonSourcePath = sourcePath
        surfaceTabBarButtonGlobalConfigPath = globalConfigPath

        let bonsplitButtons = buttons.map { button in
            let executable = executableButtons[button.id]
            let allowProjectLocalIcon = executable.map {
                CmuxConfigExecutor.isTrustedSurfaceButton(
                    $0.button,
                    workspaceCommand: $0.workspaceCommand,
                    terminalCommandSourcePath: $0.terminalCommandSourcePath,
                    surfaceTabBarConfigSourcePath: sourcePath,
                    globalConfigPath: globalConfigPath
                )
            } ?? true
            return button.bonsplitActionButton(
                configSourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalIcon: allowProjectLocalIcon
            )
        }
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtons != bonsplitButtons else { return }
        configuration.appearance.splitButtons = bonsplitButtons
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

}
