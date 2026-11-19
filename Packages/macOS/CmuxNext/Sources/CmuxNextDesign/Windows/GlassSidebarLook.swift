public import AppKit
public import CmuxNextDesignTokens

/// The variants of the glass sidebar experiment (`experiments.glassSidebarExtension`, taste build of 2026-11-19),
/// compared in Debug Settings `chrome.glassSidebar.variant`. Every variant runs the panes full-bleed to the
/// window's edges and leaves the sidebar's rows, widths and controls where they are.
public nonisolated enum GlassSidebarVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The sidebar is an inset glass panel, and the active pane's content extends, mirrored and blurred,
    /// under it (the system background extension effect, macOS 26 and later).
    case extended
    /// The inset glass panel over the window's own background, with no extension under it.
    case glassOnly
    /// The glass sidebar flush to the window's edges, the content extended under it.
    case flush

    public var tunableTitle: String {
        switch self {
        case .extended: "Inset glass, content extends under it (default)"
        case .glassOnly: "Inset glass over the window background"
        case .flush: "Flush glass, content extends under it"
        }
    }

    public static let tunable = Tunable<GlassSidebarVariant>.choice(
        "chrome.glassSidebar.variant", .sidebar, "Glass sidebar variant",
        help: "With Settings > Experimental > Glass Sidebar on: how the sidebar floats and whether the pane extends under it.",
        default: .extended, code: "GlassSidebarVariant.tunable")
}

/// What the window draws for the glass sidebar experiment, resolved from the setting and the variant.
/// Off (the default) is every field false and 0: the window is exactly as without the experiment.
public nonisolated struct GlassSidebarLook: Equatable, Sendable {
    /// The sidebar draws as a glass card (the floating sidebar's surface) while it is docked.
    public var glassSidebar: Bool
    /// The card's inset from the window's edges; 0 is flush.
    public var sidebarInset: CGFloat
    /// The active pane's content extends, mirrored and blurred, under the sidebar.
    public var extendsContent: Bool
    /// The panes reach the window's edges: no gutter, no rounded main pane, no titlebar strip.
    public var fullBleed: Bool

    public static let off = GlassSidebarLook(glassSidebar: false, sidebarInset: 0, extendsContent: false, fullBleed: false)

    public init(glassSidebar: Bool, sidebarInset: CGFloat, extendsContent: Bool, fullBleed: Bool) {
        (self.glassSidebar, self.sidebarInset, self.extendsContent, self.fullBleed) = (glassSidebar, sidebarInset, extendsContent, fullBleed)
    }

    /// The look for the setting and `variant`. `inset` is the card's inset (the floating sidebar's, the main pane
    /// gutter); Reduce Transparency keeps the card (solid, as every glass surface is then) but extends nothing.
    public static func resolve(on: Bool, variant: GlassSidebarVariant, inset: CGFloat, reduceTransparency: Bool) -> GlassSidebarLook {
        guard on else { return .off }
        // A style with no gutter (edge to edge) still floats the card: the curved pane's default gutter.
        return GlassSidebarLook(glassSidebar: true, sidebarInset: variant == .flush ? 0 : (inset > 0 ? inset : 6),
                                extendsContent: variant != .glassOnly && !reduceTransparency, fullBleed: true)
    }

    /// The sidebar card's corner radius: `mainPane` (the main pane's), or with the panes full-bleed (their corners
    /// square) concentric with the window's corners across the card's inset.
    public func cardRadius(mainPane: CGFloat, windowCornerRadius: CGFloat) -> CGFloat {
        fullBleed ? max(0, windowCornerRadius - sidebarInset) : mainPane
    }

    /// The look for the current settings (main thread: the setting and the tunable are main-actor state).
    @MainActor public static func current(reduceTransparency: Bool) -> GlassSidebarLook {
        resolve(on: DesignSettings.shared.glassSidebarExtension, variant: GlassSidebarVariant.tunable.value,
                inset: Metrics.mainPaneGutter, reduceTransparency: reduceTransparency)
    }
}
