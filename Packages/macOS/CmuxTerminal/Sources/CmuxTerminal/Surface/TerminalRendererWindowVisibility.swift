import Foundation

/// The one rule for "is the hosting window visible enough to present a renderer".
///
/// `NSWindow.occlusionState` is the authoritative signal on a real display: a
/// miniaturized, fully covered, or inactive-Space window drops the `.visible`
/// bit and the renderer is released. On a virtual/headless display (the CI
/// display-churn harness runs the app on a `CGVirtualDisplay`) AppKit never
/// raises `.visible` for a window that is nevertheless ordered in and drawing,
/// so gating presentation on that bit alone leaves the terminal at zero
/// presents forever. Until a window has reported `.visible` at least once, its
/// ordinary on-screen state is trusted instead; a key window is always visible.
public enum TerminalRendererWindowVisibility {
    public static func isVisible(
        occlusionVisible: Bool,
        windowHasReportedVisible: Bool,
        isWindowVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        if occlusionVisible || isKeyWindow { return true }
        // Occlusion has been trustworthy for this window: honor its verdict.
        if windowHasReportedVisible { return false }
        return isWindowVisible && !isMiniaturized && isOnActiveSpace
    }
}
