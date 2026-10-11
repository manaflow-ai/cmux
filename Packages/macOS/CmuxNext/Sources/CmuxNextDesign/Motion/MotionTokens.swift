public import Foundation

/// How fast chrome animates (`ui.animationSpeed` in cmux.json).
public nonisolated enum MotionSpeed: String, Sendable, CaseIterable, Codable {
    /// The default: short springs tuned for a pro tool (plans/cmux-next/motion.md).
    case fast
    /// About Apple's system pacing: every duration is 1.5 times longer.
    case normal
    /// No animation. Every change applies in one frame.
    case off

    /// Multiplier on every spring response and fade duration.
    public var timeScale: Double {
        switch self {
        case .fast: 1
        case .normal: 1.5
        case .off: 0
        }
    }
}

/// Spring tokens. Each one is a response (seconds for one undamped period)
/// and a damping fraction (1 = critically damped), as in SwiftUI
/// `.spring(response:dampingFraction:)`. Damping 0.9 overshoots 0.05% (0.1
/// pt on a 200 pt move, invisible) and ends visibly ~30% sooner than a
/// critically damped spring's long tail. Values and rationale are in
/// plans/cmux-next/motion.md; change them only there and here.
public nonisolated enum MotionSpring: String, Sendable, CaseIterable {
    /// An existing item moves or resizes: tab reflow and reorder, sidebar
    /// rows, pane and divider frames, pane zoom, toolbar height.
    case move
    /// Something appears or expands: tab grow-in, group expand, row insert,
    /// sidebar show.
    case appear
    /// Something disappears or collapses: tab close, group collapse,
    /// sidebar hide. Faster than `appear`.
    case disappear
    /// Release after direct manipulation (drop, drag cancel, ghost landing).
    /// Slightly under-damped so the carried velocity reads as physical.
    case settle
    /// Programmatic scroll: tab strip reveal, strip column reveal, wheel
    /// notch, trackpad fling snap. Stiffness 800 (response 0.222 s); damping
    /// 0.9 instead of 1 drops the slow sub-pixel tail.
    case scroll
    /// Screen switch slide.
    case screen
    /// An overlay that tracks the pointer between targets: drop zones, the
    /// drag ghost's jump between card and inline slot.
    case track
    /// Selection indicator glide (sidebar pill).
    case selection
    /// Floating panel open: palette scale-in, hover card slide.
    case panel

    /// Values at `MotionSpeed.fast`: the code default (`MotionTunables`),
    /// or its Debug Settings override in DEV and NIGHTLY builds.
    public var base: SpringParameters {
        MotionTunables.springs[self]?.value ?? SpringParameters(response: 0.2, dampingFraction: 0.9)
    }
}
