import CmuxSidebar
import SwiftUI

extension VerticalTabsSidebar {
    /// The float/dock switch, pinned to the sidebar's top-trailing corner.
    ///
    /// Placed opposite the window controls and in the same spot in both modes,
    /// so the gesture that floats the rail is the gesture that docks it again.
    /// It fades in on hover rather than sitting there permanently: a resting
    /// sidebar is a list of workspaces, and a control parked in the corner
    /// competes with the first row for the eye.
    @ViewBuilder
    var sidebarPresentationToggleOverlay: some View {
        SidebarPresentationToggleButton(
            mode: presentationMode,
            accent: Color(nsColor: cmuxAccentNSColor(for: sidebarChromeColorScheme)),
            onToggle: onTogglePresentationMode
        )
        .padding(.trailing, 8)
        .frame(height: MinimalModeChromeMetrics.titlebarHeight)
        .opacity(isHoveringTopStrip ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHoveringTopStrip)
        .onHover { isHoveringTopStrip = $0 }
        .accessibilityHidden(false)
    }
}
