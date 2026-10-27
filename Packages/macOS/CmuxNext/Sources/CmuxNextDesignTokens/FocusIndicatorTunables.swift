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
        help: "How much subtler an unfocused pane's tabs draw (0 is the same as the focused pane). 0.4 since 2026-10-21: 0.35 made the focused pane hard to tell (Cmd-W), 0.6 made the shift on a focus change jarring.",
        default: 0.4, range: 0...1, step: 0.05, unit: .fraction, code: "FocusIndicatorTunables.inactiveTabStrength")

    /// Leo 2026-10-21: a link opened beside his chat moved focus and nothing showed where. Off by
    /// default until Leo judges it live (`PaneOverlayView.flashesFocus`).
    public static let flashOnMove = Tunable<Bool>.toggle(
        "focus.flashOnMove", .focus, "Flash the ring when focus moves",
        help: "Show the focus ring briefly on the pane focus moved to without a click (a link open, the pane after a close, an agent handoff), then fade it.",
        default: false, code: "FocusIndicatorTunables.flashOnMove")

    public static var all: [TunableDescriptor] {
        [indicator.descriptor, inactiveTabStyle.descriptor, inactiveTabStrength.descriptor, flashOnMove.descriptor]
    }
}
