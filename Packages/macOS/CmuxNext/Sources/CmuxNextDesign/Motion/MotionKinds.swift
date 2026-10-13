public import Foundation

/// How springy structural motion is (`ui.animations.bounce` in cmux.json).
/// Structural springs (`move`, `appear`, `disappear`) are critically damped
/// by default: they never pass their target. `subtle` gives them SwiftUI's
/// bounce `MotionTunables.subtleBounce` (0.15).
public nonisolated enum MotionBounce: String, Sendable, CaseIterable, Codable {
    case none
    case subtle
}

/// The structural changes a user can stop animating one by one
/// (`ui.animations.splits`, `ui.animations.newTab`,
/// `ui.animations.newWorkspace`), under `ui.animationSpeed`.
public nonisolated enum MotionKind: String, Sendable, CaseIterable, Codable {
    /// Cmd-D, Cmd-Shift-D, closing a split, a divider released.
    case splits
    /// A new tab growing into its slot (Cmd-T, +, New Terminal Tab, socket).
    case newTab
    /// A new workspace row opening in the sidebar (Cmd-N).
    case newWorkspace
}

nonisolated extension MotionSpring {
    /// Structure: things that take or give up room. These follow the bounce
    /// setting; release, scroll and overlay springs keep their own damping.
    public var isStructural: Bool {
        switch self {
        case .move, .appear, .disappear: true
        default: false
        }
    }
}
