public import AppKit
public import CmuxNextDesignTokens

/// The chrome's dividers: the sidebar's edge line, the line between split panes and the tab row's divider. Under
/// one color (`appearance.titleAreaTone` oneColor, the default) they are what parts the sidebar, the panes and the
/// tab row from the content, so they draw the theme's separator (`Palette.separator`) a step stronger than a list's
/// hairline. Leo, 2026-11-12: "how about the divider tho? we still want to keep that... across most panes by
/// default. differin gwith configuration, ofc." `sidebar.border`, `layout.paneSeparation`, `appearance.borders`
/// and a theme's `splitDivider` surface still turn them off or recolor them.
nonisolated extension ChromeTunables {
    public static let dividerStrength = Tunable<Double>.number(
        "chrome.dividerStrength", .panes, "Divider strength",
        help: "How strongly the sidebar's edge line, the split panes' lines and the tab row's divider draw, as a multiple of the theme's separator alpha. 1 is a list's hairline.",
        default: 1.75, range: 0.5...4, step: 0.25, unit: .multiplier, code: "ChromeTunables.dividerStrength")

    /// The tab row's divider: a hairline under the tab strips. Off by default (Lawrence, 2026-11-15: "we still have the
    /// line below tabs which is very bad"): the tab row and the content read as one surface under every tab (terminal,
    /// browser, chat, Markdown), in Home and in a workspace, and the selected tab alone marks the row. On, the line draws
    /// at ``Metrics/tabRowDividerStrength`` (Leo's two-tone polish, 2026-11-12), still leaving out a pane whose omnibar
    /// or row-sharing content meets its tabs. The sidebar's edge line and the split lines are not this toggle's.
    public static let tabRowDivider = Tunable<Bool>.toggle(
        "chrome.tabRowDivider", .panes, "Line under the tabs",
        help: "A hairline under the tab strips, taking over from the title area tone as its contrast drops. Off: no line; the selected tab marks the row.",
        default: false, code: "ChromeTunables.tabRowDivider")
}

extension Palette {
    /// The chrome's dividers (``ChromeTunables/dividerStrength``): the separator token with its alpha scaled, so it
    /// keeps the theme's hue and goes clear under `appearance.borders` none, as the separator does.
    public static var chromeDivider: NSColor {
        let separator = separator
        let alpha = min(1, separator.alphaComponent * CGFloat(ChromeTunables.dividerStrength.value))
        return separator.withAlphaComponent(alpha)
    }

    /// A finer chrome line in the dividers' color (the tab separators, the pinned group's end): `opacity` of the
    /// separator's hue at the default ``ChromeTunables/dividerStrength``, following the strength from there, so the
    /// chrome has one divider color and each line keeps its weight beside the others.
    public static func chromeDivider(opacity: CGFloat) -> NSColor {
        let strength = ChromeTunables.dividerStrength
        return chromeDivider.withAlphaComponent(min(1, opacity * CGFloat(strength.value / strength.defaultValue)))
    }
}
