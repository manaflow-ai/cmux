/// `appearance.previousGlass` in cmux.json: off by default, so web pages draw the one glass system
/// (design/glass-system.md). On, they draw the glass numbers from before it: one tint for light and
/// dark, the old saturations, no lit top edge, the 70% see-through underlay, and content cards as
/// chrome glass (`WebTheme.glassLevels` is `previous`, webviews ui/glass/glass.css). Native surfaces
/// keep their own material; Reduce Transparency still draws every web glass solid.
public nonisolated struct PreviousGlassSetting {
    public nonisolated init() {}
}
