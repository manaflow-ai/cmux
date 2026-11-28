public import CmuxNextDesign

/// Debug alternatives for closing, expanding and restoring pane layouts.
///
/// Every choice reuses Motion tokens and the same fixed-size content hosts.
/// The standard choice preserves the shipping motion until dogfood selects a preset.
public nonisolated enum PaneMotionVariant: String, Sendable, CaseIterable, TunableChoice {
    /// The existing close reflow and pane zoom springs.
    case standard
    /// Short, critically damped movement with no overshoot.
    case crisp
    /// A small easing bump as the pane reaches its destination.
    case softLanding

    public var tunableTitle: String {
        switch self {
        case .standard: "Current"
        case .crisp: "Crisp"
        case .softLanding: "Soft landing"
        }
    }

    var closeSpring: MotionSpring {
        switch self {
        case .standard: .move
        case .crisp: .disappear
        case .softLanding: .settle
        }
    }

    var expandSpring: MotionSpring {
        switch self {
        case .standard: .zoom
        case .crisp: .move
        case .softLanding: .settle
        }
    }
}
