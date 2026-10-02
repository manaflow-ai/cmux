public import CoreGraphics

/// The Debug Settings switches for the focus cue.
public nonisolated enum FocusIndicatorTunables {
    public static let indicator = Tunable<FocusIndicator>.choice(
        "focus.indicator", .focus, "Focus indicator",
        help: "What marks the focused pane (overrides appearance.focusIndicator in cmux.json).",
        default: .both, code: "FocusIndicatorTunables.indicator")
    public static let inactiveTabStyle = Tunable<InactiveTabStyle>.choice(
        "focus.inactiveTabStyle", .focus, "Unfocused pane tabs",
        help: "Prototype: how an unfocused pane's tabs draw subtler.",
        default: .fade, code: "FocusIndicatorTunables.inactiveTabStyle")
    public static let inactiveTabStrength = Tunable<CGFloat>.number(
        "focus.inactiveTabStrength", .focus, "Unfocused tabs strength",
        help: "How much subtler an unfocused pane's tabs draw (0 is the same as the focused pane).",
        default: 0.35, range: 0...1, step: 0.05, unit: .fraction, code: "FocusIndicatorTunables.inactiveTabStrength")
    public static let tabBarBackground = Tunable<TabBarBackground>.choice(
        "focus.tabBarBackground", .focus, "Tab bar background",
        help: "Overrides appearance.tabBarBackground in cmux.json.",
        default: .window, code: "FocusIndicatorTunables.tabBarBackground")

    public static var all: [TunableDescriptor] {
        [indicator.descriptor, inactiveTabStyle.descriptor, inactiveTabStrength.descriptor, tabBarBackground.descriptor]
    }
}
