public import AppKit
public import SwiftUI

/// Shared presentation chrome resolved once per workspace render and threaded
/// into every panel view (terminal, browser, markdown, file preview, project,
/// agent session, sidebar tool).
///
/// `PanelAppearance` is a pure value: the colors and flags that drive a panel's
/// background, divider, and unfocused-overlay rendering. It carries no I/O and
/// no app-target coupling, so it lives beside the ``Panel`` protocol as part of
/// the package-pure panel vocabulary the rest of the app codes against.
///
/// The factory that derives a `PanelAppearance` from a Ghostty config
/// (`fromConfig`) stays in the app target, because it reads the app-owned
/// window-background composition policy, the Ghostty background theme, and the
/// readable-foreground color helper. Those are app concerns; the resolved value
/// is the seam.
public struct PanelAppearance {
    /// The opaque background color of the panel.
    public let backgroundColor: NSColor
    /// The readable foreground color resolved against ``backgroundColor``.
    public let foregroundColor: NSColor
    /// The color drawn on split dividers between panels.
    public let dividerColor: Color
    /// The fill color of the dimming overlay drawn over unfocused split panes.
    public let unfocusedOverlayNSColor: NSColor
    /// The opacity of the unfocused-split dimming overlay.
    public let unfocusedOverlayOpacity: Double
    /// Whether the panel content area should draw a clear (transparent)
    /// background instead of ``backgroundColor`` (e.g. transparent window or
    /// Ghostty glass styling).
    public let usesClearContentBackground: Bool

    /// Create a resolved panel appearance.
    public init(
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        dividerColor: Color,
        unfocusedOverlayNSColor: NSColor,
        unfocusedOverlayOpacity: Double,
        usesClearContentBackground: Bool
    ) {
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.dividerColor = dividerColor
        self.unfocusedOverlayNSColor = unfocusedOverlayNSColor
        self.unfocusedOverlayOpacity = unfocusedOverlayOpacity
        self.usesClearContentBackground = usesClearContentBackground
    }

    /// The background color the content layer should fill: clear when
    /// ``usesClearContentBackground`` is set, otherwise ``backgroundColor``.
    public var contentBackgroundColor: NSColor {
        usesClearContentBackground ? .clear : backgroundColor
    }

    /// Whether the content layer draws an opaque background fill.
    public var drawsContentBackground: Bool {
        !usesClearContentBackground
    }

    /// Whether the panel content background should be drawn clear given the
    /// resolved opacity and styling inputs. Pure policy; safe to evaluate
    /// without any app-target collaborators.
    public static func shouldUseClearContentBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        usesTransparentWindow || usesGhosttyGlassStyle || opacity < 0.999
    }
}
