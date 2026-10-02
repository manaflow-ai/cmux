/// How the launch mark resolves on the window glass (`LaunchMarkView`).
public nonisolated enum LaunchMarkStyle: String, Sendable, CaseIterable, TunableChoice {
    /// The outline draws itself, then the body fills in.
    case trace
    /// The mark condenses from a soft, slightly larger glow to its crisp size.
    case bloom

    public var tunableTitle: String {
        switch self {
        case .trace: "Trace"
        case .bloom: "Bloom"
        }
    }
}
