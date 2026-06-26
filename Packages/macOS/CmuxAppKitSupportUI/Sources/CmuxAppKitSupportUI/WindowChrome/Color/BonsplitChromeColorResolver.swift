public import AppKit
public import Bonsplit
import CmuxFoundation

/// Resolves the Bonsplit chrome colors (tab bar / split-button / pane / border
/// fills) for a workspace's window chrome from a terminal background color,
/// opacity, and the active backdrop rendering mode.
///
/// These are pure value computations producing
/// `BonsplitConfiguration.Appearance.ChromeColors`; the resolver holds no state.
/// The app target supplies the rendering mode (computed from the live
/// `GhosttyApp`/`WindowChromeMetrics` it owns) and calls the resolver instead of
/// using a static-method namespace on `Workspace`.
public struct BonsplitChromeColorResolver: Sendable {
    /// Creates a chrome color resolver.
    public init() {}

    /// Whether the window root host paints the terminal backdrop for all
    /// workspaces. The window root backdrop owns terminal fills.
    public func usesWindowRootTerminalBackdrop() -> Bool {
        true
    }

    /// Returns the hex string for the themed (composited) terminal surface color.
    public func bonsplitChromeHex(
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

    /// Whether Bonsplit panes should paint their own terminal backdrop fill.
    ///
    /// The window root backdrop owns terminal fills, so Bonsplit pane fills
    /// would add a second translucent layer under the Metal surface.
    public func usesBonsplitPaneTerminalBackdrop(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        sharesWindowBackdrop: Bool
    ) -> Bool {
        return false
    }

    /// Resolves the full chrome color set from the themed terminal surface color.
    public func bonsplitChromeColors(
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
        let borderHex = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColor)
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

    /// Resolves the chrome color set from a raw (non-composited) background color.
    ///
    /// Kept signature-aligned with `bonsplitChromeHex` for settings tests and
    /// future background-image handling.
    public func resolvedChromeColors(
        from backgroundColor: NSColor,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        let backgroundHex = backgroundColor.hexString()
        let borderHex = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColor)
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

    /// Field-by-field equality of two chrome color sets.
    public func bonsplitChromeColorsEqual(
        _ lhs: BonsplitConfiguration.Appearance.ChromeColors,
        _ rhs: BonsplitConfiguration.Appearance.ChromeColors
    ) -> Bool {
        lhs.backgroundHex == rhs.backgroundHex &&
            lhs.tabBarBackgroundHex == rhs.tabBarBackgroundHex &&
            lhs.splitButtonBackdropHex == rhs.splitButtonBackdropHex &&
            lhs.paneBackgroundHex == rhs.paneBackgroundHex &&
            lhs.borderHex == rhs.borderHex
    }

    /// A compact log description of a chrome color set.
    public func bonsplitChromeColorsLogDescription(
        _ colors: BonsplitConfiguration.Appearance.ChromeColors
    ) -> String {
        "bg=\(colors.backgroundHex ?? "nil") " +
            "tabBarBg=\(colors.tabBarBackgroundHex ?? "nil") " +
            "splitBackdrop=\(colors.splitButtonBackdropHex ?? "nil") " +
            "paneBg=\(colors.paneBackgroundHex ?? "nil") " +
            "border=\(colors.borderHex ?? "nil")"
    }
}
