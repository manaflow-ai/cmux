#if DEBUG
import SwiftUI

/// Draws the six-point square used for every compact Signal status mark.
struct SignalStatusSquare: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
#endif
