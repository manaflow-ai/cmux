/// How the launch mark resolves on the window glass (`LaunchMarkView`).
public nonisolated enum LaunchMarkStyle: String, Sendable, CaseIterable, TunableChoice {
    /// The outline draws itself, then the body fills in.
    case trace
    /// The mark condenses from a soft, slightly larger glow to its crisp size.
    case bloom

    /// The Debug Settings switch for the style.
    public static let tunable = Tunable<LaunchMarkStyle>.choice(
        "launch.markStyle", .fades, "Launch mark",
        help: "How the cmux mark resolves on the glass while a launch has nothing to show yet.",
        default: .bloom, code: "LaunchMarkStyle.tunable")

    public var tunableTitle: String {
        switch self {
        case .trace: "Trace"
        case .bloom: "Bloom"
        }
    }
}
