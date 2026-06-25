import AppKit
import QuartzCore
import SwiftUI

struct SidebarAgentActivityIndicator: View {
    let count: Int
    let spinnerColor: NSColor
    let foregroundColor: Color
    let backgroundColor: Color
    let fontScale: CGFloat

    var body: some View {
        HStack(spacing: max(3, 3 * fontScale)) {
            GPUSpinner(style: .macOSSpokes, color: spinnerColor)
                .frame(width: max(9, 9 * fontScale), height: max(9, 9 * fontScale))
            Text("\(count)")
                .font(.system(size: max(8, 8.5 * fontScale), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(foregroundColor)
                .lineLimit(1)
        }
        .padding(.horizontal, max(5, 5 * fontScale))
        .frame(height: max(16, 16 * fontScale))
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}
