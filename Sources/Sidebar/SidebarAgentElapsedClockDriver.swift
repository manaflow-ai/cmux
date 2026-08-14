import Foundation
import SwiftUI

/// The sole TimelineView for default-sidebar elapsed labels. Its tiny
/// representable sink keeps timeline invalidation out of the row/list tree.
@MainActor
struct SidebarAgentElapsedClockDriver: View {
    let clock: SidebarAgentElapsedClock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            SidebarAgentElapsedClockTickView(clock: clock, now: timeline.date)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// AppKit bridge used only as the narrow TimelineView invalidation sink.
@MainActor
private struct SidebarAgentElapsedClockTickView: NSViewRepresentable {
    let clock: SidebarAgentElapsedClock
    let now: Date

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        clock.tick(at: now)
    }
}
