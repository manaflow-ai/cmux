public import CoreGraphics

/// The Debug Settings switches for the focus cue.
public nonisolated enum FocusIndicatorTunables {
    public static let indicator = Tunable<FocusIndicator>.choice(
        "focus.indicator", .focus, "Focus indicator",
        help: "What marks the focused pane (overrides appearance.focusIndicator in cmux.json).",
        default: .both, code: "FocusIndicatorTunables.indicator")
    public static let inactiveTabStyle = Tunable<InactiveTabStyle>.choice(
        "focus.inactiveTabStyle", .focus, "Unfocused pane tabs",
        help: "How an unfocused pane's tabs draw subtler (overrides focus.inactiveTabStyle in cmux.json).",
        default: .fade, code: "FocusIndicatorTunables.inactiveTabStyle")
    public static let inactiveTabStrength = Tunable<CGFloat>.number(
        "focus.inactiveTabStrength", .focus, "Unfocused tabs strength",
        help: "How much subtler an unfocused pane's tabs draw (0 is the same as the focused pane). 0.6 since 2026-10-21 (was 0.35): with no ring by default, the tabs are the cue for which pane Cmd-W closes.",
        default: 0.6, range: 0...1, step: 0.05, unit: .fraction, code: "FocusIndicatorTunables.inactiveTabStrength")

    public static var all: [TunableDescriptor] {
        [indicator.descriptor, inactiveTabStyle.descriptor, inactiveTabStrength.descriptor]
    }
}
