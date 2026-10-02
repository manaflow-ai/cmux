public import CoreGraphics
public import Foundation

/// Fixed chrome constants (the 2 pt spacing grid, divider widths, insets)
/// and the glass and scroll-fade parameters, as Debug Settings tunables.
public nonisolated enum ChromeTunables {
    private static func points(_ name: String, _ section: TunableSection, _ label: String, help: String, _ value: CGFloat,
                               range: ClosedRange<Double>, step: Double = 0.5, code: String? = nil) -> Tunable<CGFloat> {
        .number("chrome.\(name)", section, label, help: help, default: value, range: range, step: step, unit: .points,
                code: code ?? "ChromeTunables.\(name)")
    }

    // MARK: Spacing grid

    public static let space1 = points("space1", .shape, "Space 1", help: "Smallest grid step.", 2, range: 0...8)
    public static let space2 = points("space2", .shape, "Space 2", help: "Grid step 2.", 4, range: 0...12)
    public static let space3 = points("space3", .shape, "Space 3", help: "Grid step 3.", 6, range: 0...16)
    public static let space4 = points("space4", .shape, "Space 4", help: "Grid step 4.", 8, range: 0...20)
    public static let space5 = points("space5", .shape, "Space 5", help: "Grid step 5.", 12, range: 0...28)
    public static let space6 = points("space6", .shape, "Space 6", help: "Largest grid step.", 16, range: 0...36)

    // MARK: Window, tabs, panes

    public static let trafficLightInset = points("trafficLightInset", .sidebar, "Traffic light inset",
                                                 help: "Space at the titlebar's leading edge for the window buttons.", 76, range: 40...140, step: 1)
    public static let sidebarMinWidth = points("sidebarMinWidth", .sidebar, "Sidebar min width", help: "Narrowest sidebar resize.", 160, range: 80...400, step: 1)
    public static let sidebarMaxWidth = points("sidebarMaxWidth", .sidebar, "Sidebar max width", help: "Widest sidebar resize.", 360, range: 200...800, step: 1)
    public static let tabBackgroundInset = points("tabBackgroundInset", .tabs, "Tab background inset",
                                                  help: "Inset of a tab's rounded background inside its slot.", 1, range: 0...8)
    public static let tabContentLeadingInset = points("tabContentLeadingInset", .tabs, "Tab content inset",
                                                      help: "Inset of a tab's icon from its slot's leading edge (the pane content line).", 8, range: 0...24)
    public static let dividerThickness = points("dividerThickness", .panes, "Divider thickness", help: "Visible line between split panes.", 1, range: 0...6)
    public static let dividerHitWidth = points("dividerHitWidth", .panes, "Divider hit width", help: "Draggable width centered on a divider.", 7, range: 1...24)
    public static let panePadding = DerivedTunable<CGFloat>.number(
        "chrome.panePadding", .panes, "Pane padding", help: "Inset around every pane's tab strip and content (0 is edge to edge). Default: layout.panePadding, else 2 compact, 4 comfortable.",
        range: 0...24, step: 0.5, unit: .points, code: "ChromeTunables.panePadding") { Metrics.codePanePadding }

    // MARK: Glass and overlays

    public static let opaqueOverlayLift = Tunable<Double>.number(
        "glass.opaqueOverlayLift", .glass, "Opaque overlay lift", help: "Reduce Transparency overlays: how far the fill moves from the background toward the text color.",
        default: 0.14, range: 0...0.6, step: 0.01, unit: .fraction, code: "ChromeTunables.opaqueOverlayLift")
    public static let glassOverlayTintStrength = Tunable<Double>.number(
        "glass.overlayTintStrength", .glass, "Overlay tint strength", help: "Multiplier on the theme glass tint's alpha for overlay surfaces (drop overlay).",
        default: 1, range: 0...3, step: 0.05, unit: .multiplier, code: "ChromeTunables.glassOverlayTintStrength")

    // MARK: Scroll fade

    public static let scrollFadeMaxFraction = Tunable<Double>.number(
        "scroll.fadeMaxFraction", .focus, "Scroll fade max share", help: "The edge fade never covers more than this share of the list height.",
        default: 0.4, range: 0...0.5, step: 0.01, unit: .fraction, code: "ChromeTunables.scrollFadeMaxFraction")

    static var fixed: [TunableDescriptor] {
        [space1, space2, space3, space4, space5, space6, trafficLightInset, sidebarMinWidth, sidebarMaxWidth, tabBackgroundInset,
         tabContentLeadingInset, dividerThickness, dividerHitWidth].map(\.descriptor)
            + [panePadding.descriptor, opaqueOverlayLift.descriptor, glassOverlayTintStrength.descriptor, scrollFadeMaxFraction.descriptor]
    }
}

/// The tunables CmuxNextDesign declares (motion, metrics, chrome). Other
/// modules declare their own lists; the App joins them (`TunableCatalog`).
public nonisolated enum DesignTunables {
    public static var all: [TunableDescriptor] {
        MotionTunables.all + MetricTunables.metrics.map(\.descriptor) + ChromeTunables.fixed + [Borders.tunable.descriptor] + FocusIndicatorTunables.all
            + StatusIndicatorTunables.all
    }
}
