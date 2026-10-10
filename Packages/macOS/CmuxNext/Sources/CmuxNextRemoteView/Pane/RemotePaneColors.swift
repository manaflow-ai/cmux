import AppKit
import CmuxNextDesign

/// Chrome colors of the pane, resolved by the pane view inside its theme
/// scope and handed to every subview. No blue: selection and hover are the
/// foreground at low alpha; the path dot uses success / attention.
struct RemotePaneColors: Equatable {
    var background = NSColor.windowBackgroundColor
    var textPrimary = NSColor.labelColor
    var textSecondary = NSColor.secondaryLabelColor
    var textTertiary = NSColor.tertiaryLabelColor
    var hoverFill = NSColor.quaternaryLabelColor
    var selectionFill = NSColor.unemphasizedSelectedContentBackgroundColor
    var badgeFill = NSColor.quaternaryLabelColor
    var separator = NSColor.separatorColor
    var attention = NSColor.systemOrange
    var danger = NSColor.systemRed
    var success = NSColor.systemGreen
    var drawsBorders = true

    /// Reads the chrome tokens; callers run it inside `performWithTheme`.
    // theme-scoped
    static func resolved() -> RemotePaneColors {
        RemotePaneColors(
            background: plain(Palette.contentBackground),
            textPrimary: plain(Palette.textPrimary), textSecondary: plain(Palette.textSecondary),
            textTertiary: plain(Palette.textTertiary), hoverFill: plain(Palette.hoverFill),
            selectionFill: plain(Palette.selectionFill), badgeFill: plain(Palette.badgeFill),
            separator: plain(Palette.separator), attention: plain(Palette.attention),
            danger: plain(Palette.danger), success: plain(Palette.success),
            drawsBorders: Borders.drawsLines)
    }

    /// The dot color of a path: green direct, amber through the cloud or relay.
    func dot(for path: RemotePath?) -> NSColor {
        switch path {
        case .direct: success
        case .viaCloudRegion, .relayed: attention
        case nil: textTertiary
        }
    }

    /// A static sRGB color: a dynamic one would re-resolve outside the scope.
    private static func plain(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
}
