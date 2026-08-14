import AppKit
import SwiftUI

/// Compact deterministic state/elapsed label placed on a workspace row.
/// Its AppKit text field registers with the sidebar's one shared clock, so a
/// tick invalidates only this realized label rather than its SwiftUI row.
struct SidebarAgentActivityLabel: NSViewRepresentable {
    let activity: SidebarWorkspaceAgentActivity
    let color: NSColor
    let fontSize: CGFloat
    let clock: SidebarAgentElapsedClockActions

    func makeNSView(context: Context) -> SidebarAgentActivityTextField {
        let view = SidebarAgentActivityTextField()
        view.configure(activity: activity, color: color, fontSize: fontSize, clock: clock)
        return view
    }

    func updateNSView(_ nsView: SidebarAgentActivityTextField, context: Context) {
        nsView.configure(activity: activity, color: color, fontSize: fontSize, clock: clock)
    }

    static func dismantleNSView(
        _ nsView: SidebarAgentActivityTextField,
        coordinator: Void
    ) {
        nsView.disconnectClock()
    }
}
