public import Foundation

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
