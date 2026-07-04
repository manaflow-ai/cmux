import SwiftUI

struct ActivePaneChromeBoundaryOverlay: View {
    let color: Color
    let height: CGFloat

    private var lineWidth: CGFloat { GhosttySurfaceActivePaneBoundaryMetrics.lineWidth }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                color.frame(height: lineWidth)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                color.frame(width: lineWidth, height: height)
                Spacer(minLength: 0)
                color.frame(width: lineWidth, height: height)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}
