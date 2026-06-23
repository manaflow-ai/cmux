public import AppKit
public import Bonsplit
import CmuxFoundation

/// Resolves the Bonsplit chrome color set (tab bar, split buttons, pane fills,
/// border) from a terminal background color, opacity, and backdrop ownership.
///
/// Pure color math composed with ``WindowChromeColorResolver`` for the
/// separator/border color and ``WindowAppearanceSnapshot/compositedTerminalColor(backgroundColor:opacity:over:)``
/// for the themed surface fill. Holds no mutable state; the composed resolver is
/// the single collaborator.
public struct BonsplitChromeColorResolver: Sendable {
    private let colorResolver: WindowChromeColorResolver

    /// Creates a Bonsplit chrome color resolver.
    /// - Parameter colorResolver: The window chrome color resolver used for
    ///   separator/border math. Defaults to a freshly constructed resolver.
    public init(colorResolver: WindowChromeColorResolver = WindowChromeColorResolver()) {
        self.colorResolver = colorResolver
    }

    /// Returns the hex string for the Bonsplit surface fill: the terminal
    /// background composited over the window background at the given opacity,
    /// emitting an alpha channel only when the result is translucent.
    public func chromeHex(
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

    /// Whether Bonsplit panes should paint their own terminal-colored fill.
    ///
    /// Always `false`: the window root backdrop owns terminal fills, so a pane
    /// fill would add a second translucent layer under the Metal surface.
    public func usesPaneTerminalBackdrop(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        sharesWindowBackdrop: Bool
    ) -> Bool {
        false
    }

    /// Resolves the full Bonsplit chrome color set from a terminal background
    /// color and opacity, compositing the surface fill over the window
    /// background.
    public func chromeColors(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        let surfaceHex = chromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let borderHex = colorResolver
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

        let paneBackgroundHex = usesPaneTerminalBackdrop(
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

    /// Resolves the Bonsplit chrome color set directly from a background color,
    /// without compositing over the window background.
    ///
    /// Kept aligned with ``chromeHex(backgroundColor:backgroundOpacity:sharesWindowBackdrop:)``
    /// for settings tests and future background-image handling.
    public func resolvedChromeColors(
        from backgroundColor: NSColor,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        let backgroundHex = backgroundColor.hexString()
        let borderHex = colorResolver
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

        let paneBackgroundHex = usesPaneTerminalBackdrop(
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

    /// Whether two chrome color sets are field-for-field equal.
    public func chromeColorsEqual(
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
    public func chromeColorsLogDescription(
        _ colors: BonsplitConfiguration.Appearance.ChromeColors
    ) -> String {
        "bg=\(colors.backgroundHex ?? "nil") " +
            "tabBarBg=\(colors.tabBarBackgroundHex ?? "nil") " +
            "splitBackdrop=\(colors.splitButtonBackdropHex ?? "nil") " +
            "paneBg=\(colors.paneBackgroundHex ?? "nil") " +
            "border=\(colors.borderHex ?? "nil")"
    }
}
