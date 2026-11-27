/// `appearance.liquidGlass` in cmux.json: off by default (Lawrence, standup 2026-11-19), so web
/// pages draw the solid look Reduce Transparency draws: the opaque surface, no blur, a hairline rim
/// (`WebTheme.glass` is `off`). On, they draw their glass (the composer, Session Info, menus,
/// popovers, tooltips and hover cards). Native surfaces keep their own material.
public nonisolated struct LiquidGlassSetting {
    public nonisolated init() {}
}
