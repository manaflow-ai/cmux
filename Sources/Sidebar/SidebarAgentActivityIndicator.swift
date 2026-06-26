import AppKit
import QuartzCore
import SwiftUI

/// The loading spinner shown on a sidebar workspace row. Just the native-style
/// GPU spokes spinner, no count badge. The caller sizes it for its slot
/// (trailing close-button corner, or the leading unread-badge slot).
struct SidebarAgentActivityIndicator: View {
    let spinnerColor: NSColor
    let side: CGFloat

    var body: some View {
        GPUSpinner(style: .macOSSpokes, color: spinnerColor)
            .frame(width: side, height: side)
            .fixedSize()
    }
}
