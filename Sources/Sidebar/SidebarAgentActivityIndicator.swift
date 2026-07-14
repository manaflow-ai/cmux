import AppKit
import SwiftUI

/// The loading spinner on a sidebar workspace row.
struct SidebarAgentActivityIndicator: View {
    let spinnerColor: NSColor
    let side: CGFloat

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(Color(nsColor: spinnerColor))
            .frame(width: side, height: side)
            .fixedSize()
    }
}
