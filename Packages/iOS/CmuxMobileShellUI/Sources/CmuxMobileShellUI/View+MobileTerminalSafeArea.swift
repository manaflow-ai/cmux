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
            let edgeSet: Edge.Set = {
                var result: Edge.Set = []
                if edges.horizontal { result.formUnion(.horizontal) }
                if edges.bottom { result.formUnion(.bottom) }
                return result
            }()
            content
                .ignoresSafeArea(.container, edges: edgeSet)
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
}
#endif
