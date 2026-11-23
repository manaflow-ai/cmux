public import CoreGraphics

/// How a picked workspace color draws on its sidebar row in the `leftRail` style (`workspaceColors.indicatorStyle`):
/// a bar at the row's leading edge, a wash of the color over the row, a tint on the title, or any mix of them.
///
/// ``standard`` is what the app draws. The Sidebar States Playground's "Workspace colors" sheet (Debug menu, DEV and
/// NIGHTLY) draws the real row in other looks beside it, so a treatment is judged in the real row, light and dark,
/// selected and not (Lawrence 2026-11-20, "make many versions of 'colors' we need this to be better").
///
/// ```swift
/// var content = options.rowContent(workspace, machine: nil)
/// content.railLook = WorkspaceRailLook(barWidth: 2, length: .row, lead: 0, rounded: false, ink: .quiet)
/// ```
public nonisolated struct WorkspaceRailLook: Hashable, Sendable {
    /// How long the bar runs.
    public enum Length: Hashable, Sendable {
        /// Down the row's whole height, inside its fill's inset.
        case row
        /// The title line's height: a short mark beside the name.
        case line
    }

    /// Which color the bar (and the title tint) takes from the picked swatch.
    public enum Ink: Hashable, Sendable {
        /// The palette swatch at full strength.
        case swatch
        /// The swatch taken toward the sidebar until it stands at a quiet contrast (``GroupColor/railRGB(_:emphasized:)``).
        case quiet
        /// The swatch with half its chroma, then taken to the same quiet contrast: a softer, grayer hue.
        case muted
    }

    /// The bar's width in points; 0 draws no bar.
    public var barWidth: CGFloat
    /// How long the bar runs.
    public var length: Length
    /// The bar's distance from the row fill's leading edge, in points: 0 sits on the edge.
    public var lead: CGFloat
    /// Round the bar's ends into a pill; square ends when false.
    public var rounded: Bool
    /// The bar's color.
    public var ink: Ink
    /// The opacity of the swatch washed over a row at rest (doubled when selected); 0 washes nothing.
    public var wash: CGFloat
    /// How far the title's ink moves toward the swatch, 0 (none) to 1; 0 leaves the title in the sidebar's ink.
    public var titleTint: CGFloat

    /// Creates a look.
    /// - Parameters:
    ///   - barWidth: The bar's width in points; 0 draws none.
    ///   - length: How long the bar runs.
    ///   - lead: The bar's distance from the row fill's leading edge.
    ///   - rounded: Round the bar's ends.
    ///   - ink: The bar's color.
    ///   - wash: The swatch's opacity over a resting row; 0 for none.
    ///   - titleTint: How far the title moves toward the swatch; 0 for none.
    public init(barWidth: CGFloat = 0, length: Length = .line, lead: CGFloat = 1.5, rounded: Bool = true, ink: Ink = .quiet,
                wash: CGFloat = 0, titleTint: CGFloat = 0) {
        self.barWidth = barWidth
        self.length = length
        self.lead = lead
        self.rounded = rounded
        self.ink = ink
        self.wash = wash
        self.titleTint = titleTint
    }

    /// What the app draws: a 3 pt quiet pill on the title's line, in the row's leading inset.
    public static let standard = WorkspaceRailLook(barWidth: 3, length: .line, lead: 1.5, rounded: true, ink: .quiet)

    /// The look draws a bar.
    var drawsBar: Bool { barWidth > 0 }
}
