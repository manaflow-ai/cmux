/// Whether a launch window shows the cmux mark on its glass while its content area waits for its
/// data, and how the mark resolves (`LaunchGlassMark`). Leo 2026-11-16: "do we have an initial load
/// logo fade in glass thing like how [a chat app] has theirs/[an issue tracker] has a thing".
public nonisolated enum LaunchGlassReveal: String, Sendable, CaseIterable, TunableChoice {
    /// No mark: the held content area stays clear glass until its data lands.
    case off
    /// `LaunchMarkStyle.bloom`.
    case bloom
    /// `LaunchMarkStyle.lens`, in a glass tile (a chat app's).
    case lens
    /// `LaunchMarkStyle.trace`.
    case trace
    /// `LaunchMarkStyle.sheen` (an issue tracker's).
    case sheen

    /// The Debug Settings switch for the reveal.
    public static let tunable = Tunable<LaunchGlassReveal>.choice(
        "launch.reveal", .fades, "Launch reveal",
        help: "The cmux mark on a launch window's glass while its content is still coming. A window whose content shows sooner never shows it.",
        default: .bloom, code: "LaunchGlassReveal.tunable")

    /// The mark's style, nil when the reveal is off.
    public var markStyle: LaunchMarkStyle? {
        switch self {
        case .off: nil
        case .bloom: .bloom
        case .lens: .lens
        case .trace: .trace
        case .sheen: .sheen
        }
    }

    public var tunableTitle: String {
        switch self {
        case .off: "Off"
        case .bloom: "Bloom"
        case .lens: "Lens"
        case .trace: "Trace"
        case .sheen: "Sheen"
        }
    }
}
