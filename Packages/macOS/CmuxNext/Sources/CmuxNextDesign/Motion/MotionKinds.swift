public import Foundation

/// How springy structural motion is (`ui.animations.bounce` in cmux.json).
/// Structural springs (`move`, `appear`, `disappear`) are critically damped
/// by default: they never pass their target. `subtle` gives them SwiftUI's
/// bounce `MotionTunables.subtleBounce` (0.15).
public nonisolated enum MotionBounce: String, Sendable, CaseIterable, Codable {
    case none
    case subtle
}

/// The structural changes a user can turn animation on or off one by one
/// (`ui.animations.newTab`, on by default; `ui.animations.newWorkspace`, off
/// by default: it applies in one frame), under `ui.animationSpeed`. Pane layout
/// (splits, closes, zoom, divider release) is `ui.paneAnimations`
/// (`MotionGate.animatesPaneLayout`).
public nonisolated enum MotionKind: String, Sendable, CaseIterable, Codable {
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
        case .move, .appear, .disappear, .tabOpen: true
        default: false
        }
    }
}
