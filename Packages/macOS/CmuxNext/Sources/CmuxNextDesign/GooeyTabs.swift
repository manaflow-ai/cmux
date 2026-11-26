/// `appearance.gooeyTabs`: how gooey the tab strip is (plans/cmux-next/gooey-tabs.md, "Levels"). Leo, 2026-11-23:
/// "presumably a less intense version should have a better case to be the default. so you guys need to try that.
/// like. subtle goo."
///
/// - `off` (the default) changes nothing anyone sees: `appearance.cornerFlush` and `appearance.titleAreaTone` apply
///   as set, and the strip's tweens stay on the critically damped tokens.
/// - `subtle` and `full` draw the selected tab as flush-goo (``CornerFlush/current``, compact density still keeps the
///   pill) over Subtle Tone (``DesignSettings/effectiveTitleAreaTone``), and run the goo springs (`GooTunables`,
///   CmuxNextTabs). Both are effective values: neither level writes the user's corner or tone setting, so going back
///   to `off` restores them as they were.
public nonisolated enum GooeyTabs: String, Sendable, CaseIterable, Codable {
    case off
    case subtle
    case full

    /// Whether the goo draws at all (`subtle` or `full`).
    public var isOn: Bool { self != .off }
}
