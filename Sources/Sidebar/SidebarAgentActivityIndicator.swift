import AppKit
import QuartzCore
import SwiftUI

/// The loading spinner on a sidebar workspace row.
struct SidebarAgentActivityIndicator: View {
    let spinnerColor: NSColor
    let side: CGFloat

    var body: some View {
        GPUSpinner(style: .macOSSpokes, color: spinnerColor)
            .frame(width: side, height: side)
            .fixedSize()
    }
}
