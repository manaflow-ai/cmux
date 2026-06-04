import CmuxMobileWorkspace
import SwiftUI

#if os(iOS)
/// Expands the terminal surface under the safe area in compact landscape so the
/// live area fills edge-to-edge, driven by the pure
/// ``MobileTerminalSafeAreaExpansionPolicy``.
private struct MobileCompactLandscapeTerminalSafeAreaCompensation: ViewModifier {
    let context: MobileTerminalSafeAreaContext
    let includesBottom: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        let edges = MobileTerminalSafeAreaExpansionPolicy.edges(
            context: context,
            hasCompactVerticalSize: verticalSizeClass == .compact,
            includesBottom: includesBottom
        )
        if edges.hasEdges {
            content
                .ignoresSafeArea(.container, edges: edges.edgeSet)
        } else {
            content
        }
    }
}

extension View {
    /// Expands the terminal under the safe area per the expansion policy.
    func mobileTerminalSafeAreaExpansion(
        context: MobileTerminalSafeAreaContext,
        includesBottom: Bool = true
    ) -> some View {
        modifier(MobileCompactLandscapeTerminalSafeAreaCompensation(
            context: context,
            includesBottom: includesBottom
        ))
    }

    /// Extends the terminal detail surface under the bottom safe area
    /// (home indicator) so the live area reaches the screen bottom edge.
    ///
    /// Apply this as the last modifier on the terminal detail content, after
    /// `navigationTitle`/`toolbar`: the surrounding `.frame` clamp and the
    /// navigation container otherwise re-impose the bottom safe area, leaving
    /// an empty home-indicator strip below the surface. `GhosttySurfaceView`
    /// owns its bottom chrome (it docks the accessory toolbar above the home
    /// indicator and reserves its height in the terminal grid), so the surface
    /// should own the bottom safe area too.
    func terminalSurfaceIgnoresBottomSafeArea() -> some View {
        ignoresSafeArea(.container, edges: .bottom)
    }
}
#endif
