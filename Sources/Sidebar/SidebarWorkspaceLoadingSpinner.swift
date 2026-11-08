import SwiftUI
import AppKit

struct SidebarWorkspaceLoadingSpinner: View {
    let side: CGFloat
    let color: NSColor
    let tooltip: String

    var body: some View {
        SidebarAgentActivityIndicator(spinnerColor: color, side: side)
            .safeHelp(tooltip)
            .accessibilityLabel(Text(tooltip))
    }
}
