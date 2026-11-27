public import CmuxNextDesign

/// Debug alternatives for closing, expanding and restoring pane layouts.
///
/// Every choice reuses Motion tokens and the same fixed-size content hosts.
/// The standard choice preserves the shipping motion until dogfood selects a preset.
public nonisolated enum PaneMotionVariant: String, Sendable, CaseIterable, TunableChoice {
    /// The tokens of the motion pairs (`MotionPair.pane`, `MotionPair.zoom`): `split` for a split
    /// and `paneClose` for a close, `zoom` for a zoom and `unzoom` for the way back. Each exit ends
    /// sooner than its enter.
    case standard
    /// Short, critically damped movement with no overshoot.
    case crisp

    public var tunableTitle: String {
        switch self {
        case .standard: "Current"
        case .crisp: "Crisp"
        }
    }

    /// A close's spring: the closed pane's neighbours springing into its space. The standard one
    /// is a split run backwards (plans/cmux-next/close-animation/DESIGN.md) in 75% of the split's
    /// time: the exit of `MotionPair.pane`.
    var closeSpring: MotionSpring {
        switch self {
        case .standard: .paneClose
        case .crisp: .disappear
        }
    }

    /// A split's spring: the new pane growing in while its chain makes room.
    var splitSpring: MotionSpring {
        switch self {
        case .standard: .split
        case .crisp: .move
        }
    }

    /// A zoom's spring: the pane growing to fill its screen.
    var expandSpring: MotionSpring {
        switch self {
        case .standard: .zoom
        case .crisp: .move
        }
    }

    /// An unzoom's spring: the zoomed pane going back to its place. The standard one is the exit
    /// of `MotionPair.zoom`, 75% of the zoom's time.
    var restoreSpring: MotionSpring {
        switch self {
        case .standard: .unzoom
        case .crisp: .move
        }
    }
}
