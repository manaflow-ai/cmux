import SwiftUI

/// Zero-sized lifetime anchor for the shared elapsed clock.
///
/// The clock owns its cancellation-aware scheduler and starts it only when a
/// realized SwiftUI/AppKit target registers. This view remains as a stable
/// sidebar background identity, but it does not create a periodic timeline.
@MainActor
struct SidebarAgentElapsedClockDriver: View {
    let clock: SidebarAgentElapsedClock

    var body: some View {
        // Keep the anchor mounted while activity is enabled. Target
        // registration is deliberately non-observed, so row realization can
        // never invalidate the lazy parent.
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
