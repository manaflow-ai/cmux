/// How the launch mark resolves on the window glass (`LaunchMarkView`).
public nonisolated enum LaunchMarkStyle: String, Sendable, CaseIterable, TunableChoice {
    /// The outline draws itself, then the body fills in.
    case trace
    /// The mark condenses from a soft, slightly larger glow to its crisp size.
    case bloom
    /// The mark sharpens from a soft blur, 4% smaller, to its crisp size (a chat app's launch). On a
    /// window's glass (`LaunchGlassMark`) it sits in a small glass tile.
    case lens
    /// The mark fades in dim, and a soft highlight sweeps across it once a `MotionLoop.sheen` period
    /// while it shows (an issue tracker's launch).
    case sheen

    /// The Debug Settings switch for the style.
    public static let tunable = Tunable<LaunchMarkStyle>.choice(
        "launch.markStyle", .fades, "Launch mark",
        help: "How the cmux mark resolves on the glass while a launch has nothing to show yet.",
        default: .bloom, code: "LaunchMarkStyle.tunable")

    public var tunableTitle: String {
        switch self {
        case .trace: "Trace"
        case .bloom: "Bloom"
        case .lens: "Lens"
        case .sheen: "Sheen"
        }
    }
}
