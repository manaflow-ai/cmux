import AppKit
import QuartzCore
import SwiftUI

/// The trailing-edge loading spinner on a sidebar workspace row. Just the
/// native-style GPU spokes spinner, no count badge, sized a bit larger than the
/// inline glyphs so it reads as a loading indicator.
struct SidebarAgentActivityIndicator: View {
    let spinnerColor: NSColor
    let fontScale: CGFloat

    private var side: CGFloat { max(14, 14 * fontScale) }

    var body: some View {
        GPUSpinner(style: .macOSSpokes, color: spinnerColor)
            .frame(width: side, height: side)
            .fixedSize()
    }
}
