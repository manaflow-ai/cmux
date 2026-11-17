public import CmuxNextDesignTokens
public import CoreGraphics

/// The knobs of a floating pane's look (Debug Settings > Floating Pane, DEV and NIGHTLY): its background, a
/// material behind it, a tint, the border, the shadow and the corners. The palette's "Debug: Floating Pane
/// Look" opens this section; each open floating pane redraws as a knob moves. Release and RC never activate the
/// store, so they keep these defaults. A value is local to the app and is not in the session. Labels are English
/// developer text, as for every Debug Settings section (`TunableSection`).
public nonisolated struct FloatingPaneTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "floatingPane", title: "Floating Pane", symbol: "macwindow.on.rectangle", order: 15)

    public static let backgroundOpacity = Tunable<Double>.number(
        "floatingPane.backgroundOpacity", section, "Background opacity",
        help: "The opacity of the pane's background. Below 1 the panes under it show through; a terminal's text stays solid. A browser page stays opaque.",
        default: 1, range: 0...1, step: 0.05, unit: .fraction, code: "FloatingPaneTunables.backgroundOpacity")
    public static let material = Tunable<FloatingPaneMaterial>.choice(
        "floatingPane.material", section, "Material",
        help: "A system material behind the background: it blurs what is under the pane. It shows when the background opacity is below 1.",
        default: .none, code: "FloatingPaneTunables.material")
    public static let tint = Tunable<TunableColor>.color(
        "floatingPane.tint", section, "Tint",
        help: "A theme colour over the background, at the tint strength.",
        default: .glassTint, code: "FloatingPaneTunables.tint")
    public static let tintStrength = Tunable<Double>.number(
        "floatingPane.tintStrength", section, "Tint strength",
        help: "The opacity of the tint. 0: no tint.",
        default: 0, range: 0...1, step: 0.05, unit: .fraction, code: "FloatingPaneTunables.tintStrength")
    public static let borderWidth = Tunable<Double>.number(
        "floatingPane.borderWidth", section, "Border width",
        help: "The width of the line around the pane. 0: no line.",
        default: 1, range: 0...6, step: 0.5, unit: .points, code: "FloatingPaneTunables.borderWidth")
    public static let borderOpacity = Tunable<Double>.number(
        "floatingPane.borderOpacity", section, "Border opacity",
        help: "The opacity of the line around the pane.",
        default: 1, range: 0...1, step: 0.05, unit: .fraction, code: "FloatingPaneTunables.borderOpacity")
    public static let shadowOpacity = Tunable<Double>.number(
        "floatingPane.shadowOpacity", section, "Shadow opacity",
        help: "The opacity of the shadow under the pane. 0: no shadow.",
        default: 0.35, range: 0...1, step: 0.05, unit: .fraction, code: "FloatingPaneTunables.shadowOpacity")
    public static let shadowBlur = Tunable<Double>.number(
        "floatingPane.shadowBlur", section, "Shadow blur",
        help: "The blur radius of the shadow.",
        default: 14, range: 0...60, step: 1, unit: .points, code: "FloatingPaneTunables.shadowBlur")
    public static let shadowOffset = Tunable<Double>.number(
        "floatingPane.shadowOffset", section, "Shadow offset",
        help: "How far below the pane the shadow lies. A negative value puts it above.",
        default: 4, range: -30...30, step: 1, unit: .points, code: "FloatingPaneTunables.shadowOffset")
    /// What the corners follow. The first knob of the corners: the two other modes are there to compare.
    public static let cornerMode = Tunable<FloatingPaneCornerMode>.choice(
        "floatingPane.cornerMode", section, "Corner mode",
        help: "Concentric with the window: a corner is the window's radius less its distance from the window's edges, and never below the corner floor. The window's radius: each corner has the window's radius at each place. Main pane's radius: each corner has the main pane's radius.",
        default: .concentric, code: "FloatingPaneTunables.cornerMode")
    /// The corner floor's default: the one constant. The rim is 5 pt, so the content's corner stays round (1 pt)
    /// and a pane away from the window's edges does not look square.
    public static let defaultCornerFloor: Double = 6
    /// The smallest corner radius of the concentric mode. A corner near a corner of the window is rounder than this.
    public static let cornerFloor = Tunable<Double>.number(
        "floatingPane.cornerFloor", section, "Corner floor",
        help: "The smallest corner radius when the corner mode is concentric with the window. A corner is the window's radius less its distance from the window's edges, and never below this.",
        default: defaultCornerFloor, range: 0...40, step: 0.5, unit: .points, code: "FloatingPaneTunables.cornerFloor")
    /// The resize band's and the corner zone's defaults: the 2 constants of a pointer's reach.
    public static let defaultResizeBand: Double = 12, defaultCornerZone: Double = 20
    /// The width of the band on each edge that a pointer resizes the pane by: this value less 4 pt is outside the
    /// card's edge; inside the edge the band is the top 4 pt of the bar, and the rim on the 3 other sides.
    public static let resizeBand = Tunable<Double>.number(
        "floatingPane.resizeBand", section, "Resize band",
        help: "The width of the band on each edge that resizes the pane. This value less 4 pt is outside the card's edge, over the panes below. Inside the edge the band is the top 4 pt of the bar, and the rim on the 3 other sides. At an edge of the pane area the band outside is only the room that is there.",
        default: defaultResizeBand, range: 4...24, step: 1, unit: .points, code: "FloatingPaneTunables.resizeBand")
    /// The side of the square at each corner that resizes 2 edges, from the band's outer corner.
    public static let cornerZone = Tunable<Double>.number(
        "floatingPane.cornerZone", section, "Corner zone",
        help: "The side of the square at each corner that resizes 2 edges. The square starts at the outer corner of the resize band.",
        default: defaultCornerZone, range: 10...40, step: 1, unit: .points, code: "FloatingPaneTunables.cornerZone")

    public static var all: [TunableDescriptor] {
        [backgroundOpacity.descriptor, material.descriptor, tint.descriptor, tintStrength.descriptor, borderWidth.descriptor,
         borderOpacity.descriptor, shadowOpacity.descriptor, shadowBlur.descriptor, shadowOffset.descriptor, cornerMode.descriptor,
         cornerFloor.descriptor, resizeBand.descriptor, cornerZone.descriptor]
    }
}

/// A floating pane's look as its card draws it: the knobs' values now (``FloatingPaneTunables``).
public nonisolated struct FloatingPaneLook: Equatable, Sendable {
    public var backgroundOpacity: CGFloat = 1
    public var material: FloatingPaneMaterial = .none
    public var tint: TunableColor = .glassTint
    public var tintStrength: CGFloat = 0
    public var borderWidth: CGFloat = 1
    public var borderOpacity: CGFloat = 1
    public var shadowOpacity: CGFloat = 0.35
    public var shadowBlur: CGFloat = 14
    public var shadowOffset: CGFloat = 4
    /// What the corners follow, and the smallest corner radius of the concentric mode.
    public var cornerMode: FloatingPaneCornerMode = .concentric
    public var cornerFloor = CGFloat(FloatingPaneTunables.defaultCornerFloor)
    /// The width of the resize band on each edge and the side of the corner zone (`FloatingPaneReach`).
    public var resizeBand = CGFloat(FloatingPaneTunables.defaultResizeBand)
    public var cornerZone = CGFloat(FloatingPaneTunables.defaultCornerZone)

    public init() {}

    /// The knobs' values now. Read in a tracked scope, it registers a dependency on each knob.
    public static var current: FloatingPaneLook {
        var look = FloatingPaneLook()
        look.backgroundOpacity = unit(FloatingPaneTunables.backgroundOpacity.value)
        look.material = FloatingPaneTunables.material.value
        look.tint = FloatingPaneTunables.tint.value
        look.tintStrength = unit(FloatingPaneTunables.tintStrength.value)
        look.borderWidth = max(0, CGFloat(FloatingPaneTunables.borderWidth.value))
        look.borderOpacity = unit(FloatingPaneTunables.borderOpacity.value)
        look.shadowOpacity = unit(FloatingPaneTunables.shadowOpacity.value)
        look.shadowBlur = max(0, CGFloat(FloatingPaneTunables.shadowBlur.value))
        look.shadowOffset = CGFloat(FloatingPaneTunables.shadowOffset.value)
        look.cornerMode = FloatingPaneTunables.cornerMode.value
        look.cornerFloor = max(0, CGFloat(FloatingPaneTunables.cornerFloor.value))
        look.resizeBand = CGFloat(min(max(FloatingPaneTunables.resizeBand.value, 4), 24))
        look.cornerZone = CGFloat(min(max(FloatingPaneTunables.cornerZone.value, 10), 40))
        return look
    }

    /// Whether the panes under the floating pane show through its background: the pane's content then paints no
    /// ground of its own (``PaneGroundOwning``) and its card paints the one ground.
    public var isSeeThrough: Bool { backgroundOpacity < 1 }

    private static func unit(_ value: Double) -> CGFloat { CGFloat(min(max(value, 0), 1)) }
}
