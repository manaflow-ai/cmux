public import Foundation

/// How much slower than real time the Motion Inspector plays cmux's motion (Debug > Debug Windows >
/// Motion Inspector, `debug.motion` `time_scale`, `scripts/cmux-next/motion.py scale`). A review tool:
/// never a user setting, never persisted.
public nonisolated enum MotionTimeScale: Sendable, Equatable, Hashable, CaseIterable {
    /// Real time.
    case x1
    case x2
    case x5
    case x10
    /// Nothing moves; ``MotionTimeScale`` steps advance one display frame at a time.
    case paused

    /// Seconds of wall time one second of animation takes: 1, 2, 5, 10; infinite when paused.
    public var slowdown: Double {
        switch self {
        case .x1: 1
        case .x2: 2
        case .x5: 5
        case .x10: 10
        case .paused: .infinity
        }
    }

    /// Animation seconds per wall second: the inverse of ``slowdown`` (0 when paused). A layer's
    /// `speed` and a clock's `dt` factor.
    public var rate: Double {
        switch self {
        case .paused: 0
        default: 1 / slowdown
        }
    }

    /// The factor an animation that cannot pause (one AppKit or SwiftUI steps on the main thread,
    /// a terminal's color blend, a web page's CSS) is lengthened by when it starts: ``slowdown``,
    /// or the slowest step (10) while paused, so it still plays out slowly enough to watch.
    public var startScale: Double {
        switch self {
        case .paused: MotionTimeScale.x10.slowdown
        default: slowdown
        }
    }

    /// The scale for a socket or CLI value: 1, 2, 5, 10, or 0 for paused; nil for any other number.
    public init?(value: Double) {
        guard let scale = Self.allCases.first(where: { $0.value == value }) else { return nil }
        self = scale
    }

    /// The socket and CLI value: 1, 2, 5, 10, or 0 for paused.
    public var value: Double {
        self == .paused ? 0 : slowdown
    }
}

/// The Motion Inspector as the appearance settings hold it while it inspects (`DesignSettings.activeMotionInspector`):
/// an object the settings keep and give back, nothing more. The gates read it as CmuxNextDesign's `MotionInspector`.
@MainActor public protocol MotionInspecting: AnyObject {}

/// What the Motion Inspector changes in the motion policy while it inspects: in memory only, read
/// by ``MotionPolicy`` through `Motion.basePolicy` and by the web theme (DesignSettings).
public nonisolated struct MotionInspection: Sendable, Equatable {
    /// The time scale applied to every motion path.
    public var timeScale: MotionTimeScale
    /// Categories the filter leaves out: their animations apply in one frame, as with their
    /// `ui.animations.<category>` off, so only the kinds under review move. Empty: no filter.
    public var excludedCategories: Set<MotionCategory>

    /// No inspection: real time, every category.
    public static let off = MotionInspection(timeScale: .x1, excludedCategories: [])

    public init(timeScale: MotionTimeScale, excludedCategories: Set<MotionCategory>) {
        self.timeScale = timeScale
        self.excludedCategories = excludedCategories
    }

    /// The categories left out when only `kept` animate (nil keeps every category).
    public static func excluded(keeping kept: Set<MotionCategory>?) -> Set<MotionCategory> {
        guard let kept else { return [] }
        return Set(MotionCategory.allCases).subtracting(kept)
    }
}
