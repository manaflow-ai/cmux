import AppKit
import Foundation
import SwiftUI

/// AppKit bridge used only as the narrow TimelineView invalidation sink.
@MainActor
struct SidebarAgentElapsedClockTickView: NSViewRepresentable {
    let clock: SidebarAgentElapsedClock
    let now: Date

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        clock.tick(at: now)
    }
}
