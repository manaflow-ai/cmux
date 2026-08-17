import Foundation
import SwiftUI

/// The sole TimelineView for default-sidebar elapsed labels. Its tiny
/// representable sink keeps timeline invalidation out of the row/list tree.
@MainActor
struct SidebarAgentElapsedClockDriver: View {
    let clock: SidebarAgentElapsedClock

    var body: some View {
        Group {
            if clock.hasTargets {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    SidebarAgentElapsedClockTickView(clock: clock, now: timeline.date)
                }
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
