public import CmuxNextDesign

/// Debug alternatives for closing, expanding and restoring pane layouts.
///
/// Every choice reuses Motion tokens and the same fixed-size content hosts.
/// The standard choice preserves the shipping motion until dogfood selects a preset.
public nonisolated enum PaneMotionVariant: String, Sendable, CaseIterable, TunableChoice {
    /// The split spring (`split`) for splits and closes, and the zoom spring (`zoom`, critically
    /// damped, DESIGN.md 2026-10-18 "Spring").
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

    /// A close's spring: the closed pane's neighbours springing into its space. The standard one
    /// is the split's (plans/cmux-next/close-animation/DESIGN.md): a close is a split run backwards.
    var closeSpring: MotionSpring {
        switch self {
        case .standard: .split
        case .crisp: .disappear
        case .softLanding: .settle
        }
    }

    /// A split's spring: the new pane growing in while its chain makes room.
    var splitSpring: MotionSpring {
        switch self {
        case .standard: .split
        case .crisp: .move
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
