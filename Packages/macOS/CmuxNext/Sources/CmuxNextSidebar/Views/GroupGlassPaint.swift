import CmuxNextDesign

/// A glass group header's paint: Leo's tinted pane, held visible.
///
/// Leo's tinted glass (2026-11-05, #36225): the shared `group` surface role's veil, tinted by the group's color raised
/// in chroma (`GroupTint.glassRGB`, `sidebar.groupGlass` sets how much); a group with no color is the same glass
/// untinted. Held visible (Lawrence 2026-11-05: "groups must always have a visible bg color"): when the pane, as seen
/// over the sidebar's opaque background, falls under `GroupBackground.minimumVisibleContrast` it is pushed away from
/// the sidebar and painted at the pane's own opacity, or the least above it that shows that color. Under Reduce Transparency the paint is opaque.
struct GroupGlassPaint {
    /// What to paint: translucent, or opaque under Reduce Transparency.
    let fill: ThemeRGB
    /// The pane as seen over the sidebar's opaque background: the color the invariant measures.
    let shown: ThemeRGB
    /// The ink every glyph on the pane takes, held at text contrast over ``shown``.
    let ink: ThemeRGB

    /// The paint for a group colored `tint`, with `steps` (hover, drop) laid over the pane, bottom first.
    @MainActor init(tint: GroupTint, themed: Bool, glass: SidebarGroupGlass, tokens: ThemeTokens,
                    steps: [ThemeRGB] = [], opaque: Bool) {
        let role = FloatingGlassStyle.group.look(isDark: tokens.isDark)
        let veil = ThemeRGB(red: role.veil.white, green: role.veil.white, blue: role.veil.white, alpha: role.veil.alpha)
        var fill = steps.reduce(over(tint.glassRGB(themed: themed).withAlpha(glass.tint(dark: tokens.isDark)), veil)) { over($1, $0) }
        let ground = tokens.sidebarBackground.withAlpha(1)
        var shown = fill.composited(over: ground).withAlpha(1)
        if shown.contrast(with: ground) < GroupBackground.minimumVisibleContrast {
            shown = GroupBackground.visible(shown, over: ground)
            fill = GroupBackground.glassFill(showing: shown, over: ground, opacity: fill.alpha)
        }
        self.fill = opaque ? shown : fill
        self.shown = shown
        ink = ThemeTokens.readable(tokens.textPrimary.withAlpha(1), over: shown, minimum: ThemeTokens.minimumTextContrast)
    }
}

/// `top` painted over `bottom`, both possibly translucent (source-over): the pane stays see-through.
private func over(_ top: ThemeRGB, _ bottom: ThemeRGB) -> ThemeRGB {
    let alpha = top.alpha + bottom.alpha * (1 - top.alpha)
    guard alpha > 0 else { return top }
    func mix(_ t: Double, _ b: Double) -> Double { (t * top.alpha + b * bottom.alpha * (1 - top.alpha)) / alpha }
    return ThemeRGB(red: mix(top.red, bottom.red), green: mix(top.green, bottom.green), blue: mix(top.blue, bottom.blue), alpha: alpha)
}
