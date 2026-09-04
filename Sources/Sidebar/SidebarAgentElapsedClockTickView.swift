import AppKit
import Foundation
import SwiftUI

/// Legacy AppKit bridge retained for callers that manually inject a clock tick.
/// The production elapsed clock now schedules ticks only while targets exist.
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
