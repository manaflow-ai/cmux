import Foundation

/// The app-side host that resolves remote targets to live windows and answers
/// the mode-availability gate. Window resolution, `FileExplorerState`, and the
/// `UserDefaults`-backed beta-feature gates stay app-side behind this seam.
@MainActor
public protocol RightSidebarRemoteHosting: AnyObject {
    /// Resolves the target to its window, state, and preferred window in one
    /// pass, matching the order the interpreter then branches on.
    func rightSidebarRemoteResolution(for target: RightSidebarRemoteTarget) -> RightSidebarRemoteResolution
    /// Whether the mode is currently available (gated by live beta-feature
    /// settings the package does not read).
    func isRightSidebarModeAvailable(_ mode: RightSidebarMode) -> Bool
}
