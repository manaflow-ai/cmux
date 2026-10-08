public import CmuxNextDesign
public import CoreGraphics

/// Debug Settings tunables of the drop overlay: the style, the parameters
/// every style shares, and each style's own. The default style is the
/// border-only outline (tab-dnd); the others keep their original look.
public nonisolated enum DropOverlayTunables {
    /// `property` is the static property's name, for "Copy as Swift defaults".
    private static func number(_ name: String, _ label: String, help: String, _ value: Double, range: ClosedRange<Double>,
                               step: Double, unit: TunableUnit, property: String) -> Tunable<Double> {
        .number("drop.overlay.\(name)", .dropOverlay, label, help: help, default: value, range: range, step: step, unit: unit,
                code: "DropOverlayTunables.\(property)")
    }

    private static func toggle(_ name: String, _ label: String, help: String, _ value: Bool, property: String) -> Tunable<Bool> {
        .toggle("drop.overlay.\(name)", .dropOverlay, label, help: help, default: value, code: "DropOverlayTunables.\(property)")
    }

    // MARK: Shared

    public static let style = Tunable<DropOverlayStyle>.choice(
        "drop.overlay.style", .dropOverlay, "Style", help: "How the overlay shows where a dragged tab lands. Switches live, even mid-drag.",
        default: .outline, code: "DropOverlayTunables.style")
    public static let spring = Tunable<MotionSpring>.choice(
        "drop.overlay.spring", .dropOverlay, "Spring", help: "Motion token for the overlay moving between targets (morph always uses settle).",
        default: .track, code: "DropOverlayTunables.spring")
    public static let animated = toggle("animated", "Animate between targets", help: "Off snaps to each target in one frame.", true, property: "animated")
    public static let appearInset = number("appearInset", "Appear inset", help: "On first show the overlay grows from this share smaller than the target.",
                                           0.03, range: 0...0.3, step: 0.01, unit: .fraction, property: "appearInset")
    public static let opacity = number("opacity", "Opacity", help: "Opacity of the whole overlay.", 1, range: 0.1...1, step: 0.05, unit: .fraction, property: "opacity")
    public static let floatingInset = DerivedTunable<CGFloat>.number(
        "drop.overlay.floatingInset", .dropOverlay, "Floating inset", help: "Inset of the overlay inside a pane without pane chrome, and in column gaps. Default: Space 2.",
        range: 0...24, step: 0.5, unit: .points, code: "DropOverlayTunables.floatingInset") { Metrics.space2 }
    public static let cornerRadius = number("cornerRadius", "Corner radius", help: "-1 follows the pane (or panel) corner radius.",
                                            -1, range: -1...40, step: 0.5, unit: .points, property: "cornerRadius")
    public static let showLabel = toggle("showLabel", "Label", help: "Show the drop label (Split Right, Move Here).", true, property: "showLabel")
    public static let labelMinWidth = number("labelMinWidth", "Label minimum width", help: "Targets narrower than this hide the label.",
                                             90, range: 0...400, step: 1, unit: .points, property: "labelMinWidth")
    public static let color = Tunable<TunableColor>.color(
        "drop.overlay.color", .dropOverlay, "Line color", help: "Theme color of lines, frames, brackets and glows (no blue).",
        default: .textPrimary, code: "DropOverlayTunables.color")

    // MARK: Per style

    public static let outlineWidth = number("glassOutline.width", "Glass outline: band width", help: "Width of the glass band.", 6, range: 1...30, step: 0.5, unit: .points, property: "outlineWidth")
    public static let cardWidthFraction = number("insetCard.widthFraction", "Inset card: width share", help: "Card width as a share of the target.",
                                                 0.6, range: 0.2...1, step: 0.05, unit: .fraction, property: "cardWidthFraction")
    public static let cardMaxWidth = number("insetCard.maxWidth", "Inset card: max width", help: "Widest the card gets.", 280, range: 80...600, step: 2, unit: .points, property: "cardMaxWidth")
    public static let cardHeight = number("insetCard.height", "Inset card: height", help: "Card height.", 56, range: 24...160, step: 2, unit: .points, property: "cardHeight")
    public static let cardRegionOpacity = number("insetCard.regionOpacity", "Inset card: region tint", help: "Tint of the whole target behind the card.",
                                                 0.08, range: 0...0.5, step: 0.01, unit: .fraction, property: "cardRegionOpacity")
    public static let cardShowsIcon = toggle("insetCard.icon", "Inset card: icon", help: "Show the split direction glyph.", true, property: "cardShowsIcon")
    public static let splitGap = number("splitPreview.gap", "Split preview: gap", help: "Gap between the two resulting panes.", 6, range: 0...30, step: 0.5, unit: .points, property: "splitGap")
    public static let splitExistingOpacity = number("splitPreview.existingOpacity", "Split preview: existing pane", help: "Strength of the existing pane's outline.",
                                                    0.5, range: 0...1, step: 0.05, unit: .fraction, property: "splitExistingOpacity")
    public static let lineWidth = number("insertionLine.width", "Insertion line: width", help: "Thickness of the caret.", 4, range: 1...16, step: 0.5, unit: .points, property: "lineWidth")
    public static let lineLength = number("insertionLine.length", "Insertion line: length", help: "Caret length as a share of the edge.",
                                          0.86, range: 0.1...1, step: 0.02, unit: .fraction, property: "lineLength")
    public static let lineRegionOpacity = number("insertionLine.regionOpacity", "Insertion line: region tint", help: "Faint tint of the target region.",
                                                 0.05, range: 0...0.5, step: 0.01, unit: .fraction, property: "lineRegionOpacity")
    public static let glowWidth = number("edgeGlow.width", "Edge glow: depth", help: "How far the glow reaches into the target.", 56, range: 8...240, step: 2, unit: .points, property: "glowWidth")
    public static let glowOpacity = number("edgeGlow.opacity", "Edge glow: strength", help: "Opacity at the edge.", 0.32, range: 0...1, step: 0.02, unit: .fraction, property: "glowOpacity")
    public static let ghostWidth = number("tabGhost.width", "Tab ghost: width", help: "Width of the tab pill.", 168, range: 60...320, step: 2, unit: .points, property: "ghostWidth")
    public static let ghostRegionOpacity = number("tabGhost.regionOpacity", "Tab ghost: region tint", help: "Tint of the target behind the pill.",
                                                  0.06, range: 0...0.5, step: 0.01, unit: .fraction, property: "ghostRegionOpacity")
    public static let dimAmount = number("dimOthers.amount", "Spotlight: dim", help: "How dark everything outside the target gets.", 0.38, range: 0...0.9, step: 0.02, unit: .fraction, property: "dimAmount")
    public static let dimOutline = toggle("dimOthers.outline", "Spotlight: hairline", help: "Draw a hairline around the lit target.", true, property: "dimOutline")
    public static let morphStartWidth = number("morph.startWidth", "Morph: start width", help: "Width of the card the overlay grows from at the pointer.",
                                               72, range: 16...240, step: 2, unit: .points, property: "morphStartWidth")
    public static let hairlineWidth = number("hairline.width", "Hairline: width", help: "0 is one device pixel.", 0, range: 0...6, step: 0.25, unit: .points, property: "hairlineWidth")
    public static let hairlineOpacity = number("hairline.opacity", "Hairline: opacity", help: "Opacity of the frame line.", 0.75, range: 0.05...1, step: 0.05, unit: .fraction, property: "hairlineOpacity")
    public static let dashLength = number("dashed.dash", "Dashed: dash", help: "Dash length.", 7, range: 1...40, step: 0.5, unit: .points, property: "dashLength")
    public static let dashGap = number("dashed.gap", "Dashed: gap", help: "Gap between dashes.", 5, range: 1...40, step: 0.5, unit: .points, property: "dashGap")
    public static let dashWidth = number("dashed.width", "Dashed: width", help: "Line width.", 1.5, range: 0.5...8, step: 0.25, unit: .points, property: "dashWidth")
    public static let cornerLength = number("corners.length", "Brackets: length", help: "Length of each bracket arm.", 22, range: 4...120, step: 1, unit: .points, property: "cornerLength")
    public static let cornerWidth = number("corners.width", "Brackets: width", help: "Line width of the brackets.", 2.5, range: 0.5...10, step: 0.25, unit: .points, property: "cornerWidth")

    public static var all: [TunableDescriptor] {
        [style.descriptor, spring.descriptor, animated.descriptor, appearInset.descriptor, opacity.descriptor, floatingInset.descriptor,
         cornerRadius.descriptor, showLabel.descriptor, labelMinWidth.descriptor, color.descriptor,
        ] + DropOutlineTunables.all
            + [outlineWidth, cardWidthFraction, cardMaxWidth, cardHeight, cardRegionOpacity].map(\.descriptor)
            + [cardShowsIcon.descriptor]
            + [splitGap, splitExistingOpacity, lineWidth, lineLength, lineRegionOpacity, glowWidth, glowOpacity, ghostWidth,
               ghostRegionOpacity, dimAmount].map(\.descriptor)
            + [dimOutline.descriptor]
            + [morphStartWidth, hairlineWidth, hairlineOpacity, dashLength, dashGap, dashWidth, cornerLength, cornerWidth].map(\.descriptor)
    }
}

/// The layout's other tunables: drop zone geometry, pane dimming and
/// minimum size, the focus ring's look.
public nonisolated enum LayoutTunables {
    public static let dropEdgeFraction = Tunable<CGFloat>.number(
        "drop.edgeFraction", .tabDrag, "Edge zone share", help: "Share of a pane's extent that counts as an edge (split) drop zone.",
        default: 0.28, range: 0.05...0.5, step: 0.01, unit: .fraction, code: "LayoutTunables.dropEdgeFraction")
    public static let dropEdgeMinimum = Tunable<CGFloat>.number(
        "drop.edgeMinimum", .tabDrag, "Edge zone minimum", help: "The edge band is at least this wide.", default: 28, range: 4...200, step: 1,
        unit: .points, code: "LayoutTunables.dropEdgeMinimum")
    public static let dropEdgeMaximum = Tunable<CGFloat>.number(
        "drop.edgeMaximum", .tabDrag, "Edge zone maximum", help: "The edge band is at most this wide.", default: 180, range: 20...600, step: 1,
        unit: .points, code: "LayoutTunables.dropEdgeMaximum")
    public static let dropZoneHysteresis = Tunable<CGFloat>.number(
        "drop.zoneHysteresis", .tabDrag, "Zone hysteresis", help: "How far past a zone line the pointer goes before the preview changes zone.",
        default: 12, range: 0...60, step: 1, unit: .points, code: "LayoutTunables.dropZoneHysteresis")
    public static let newColumnDropWidth = Tunable<CGFloat>.number(
        "drop.newColumnWidth", .tabDrag, "New column zone width", help: "Width of the new-column drop zone centered on each column gap.",
        default: 36, range: 8...160, step: 1, unit: .points, code: "LayoutTunables.newColumnDropWidth")
    public static let inactivePaneDimming = Tunable<CGFloat>.number(
        "panes.inactiveDimming", .panes, "Inactive pane dim", help: "Dim of unfocused panes when dimming is on.", default: 0.14, range: 0...0.8, step: 0.01,
        unit: .fraction, code: "LayoutTunables.inactivePaneDimming")
    public static let minimumContentWidth = Tunable<CGFloat>.number(
        "panes.minimumContentWidth", .panes, "Minimum pane width", help: "Smallest content width a pane keeps (about 25 columns).", default: 200,
        range: 60...600, step: 2, unit: .points, code: "LayoutTunables.minimumContentWidth")
    public static let minimumContentHeight = Tunable<CGFloat>.number(
        "panes.minimumContentHeight", .panes, "Minimum pane height", help: "Smallest content height a pane keeps below its tab strip (about 4 rows).",
        default: 64, range: 16...400, step: 2, unit: .points, code: "LayoutTunables.minimumContentHeight")
    public static let focusRingAlpha = Tunable<CGFloat>.number(
        "focus.ringAlpha", .focus, "Focus ring alpha", help: "Alpha of the theme focus color for the ring (when focusRing.color is unset). Overrides focusRing.contrast: subtle 0.2, standard 0.55, strong 0.85.",
        default: 0.2, range: 0...1, step: 0.01, unit: .fraction, code: "LayoutTunables.focusRingAlpha")
    public static let focusGlowAlpha = Tunable<CGFloat>.number(
        "focus.glowAlpha", .focus, "Focus glow edge alpha", help: "Glow style: the edge line's alpha relative to the ring color.",
        default: 0.6, range: 0...1, step: 0.01, unit: .fraction, code: "LayoutTunables.focusGlowAlpha")
    public static let focusGlowRadiusFactor = Tunable<CGFloat>.number(
        "focus.glowRadiusFactor", .focus, "Focus glow radius", help: "Glow style: blur radius as a multiple of the ring width (at least 2 pt).",
        default: 3, range: 0...12, step: 0.25, unit: .multiplier, code: "LayoutTunables.focusGlowRadiusFactor")

    public static let prototypeModel = Tunable<LayoutPrototypeModel>.choice(
        "layout.prototype.model", .panes, "Layout model prototype",
        help: "Draws the current screen as another layout model (plans/cmux-next/layout-model.md). View only; nothing is saved.",
        default: .off, code: "LayoutTunables.prototypeModel")
    public static let prototypeDockEdge = Tunable<LayoutPrototypeDockEdge>.choice(
        "layout.prototype.dockEdge", .panes, "Prototype dock edge", help: "Frame prototype: the edge the right docked column sits on.",
        default: .bottom, code: "LayoutTunables.prototypeDockEdge")

    public static let prototypeOrientation = Tunable<LayoutPrototypeOrientation>.choice(
        "layout.prototype.orientation", .panes, "Prototype frame orientation",
        help: "Frame prototype: column-major (side docks full height) or row-major (top/bottom docks full width).",
        default: .columnMajor, code: "LayoutTunables.prototypeOrientation")

    public static let prototypeDockMode = Tunable<LayoutPrototypeDockMode>.choice(
        "layout.prototype.dockMode", .panes, "Prototype dock mode",
        help: "Frame prototype: pinned or overlay for docks drawn from plain columns (real docked columns keep their own mode).",
        default: .pinned, code: "LayoutTunables.prototypeDockMode")

    public static var all: [TunableDescriptor] {
        [prototypeModel.descriptor, prototypeDockEdge.descriptor, prototypeOrientation.descriptor, prototypeDockMode.descriptor] + DropOverlayTunables.all + [dropEdgeFraction, dropEdgeMinimum, dropEdgeMaximum, dropZoneHysteresis, newColumnDropWidth, inactivePaneDimming,
                                   minimumContentWidth, minimumContentHeight, focusRingAlpha, focusGlowAlpha, focusGlowRadiusFactor].map(\.descriptor)
    }
}
