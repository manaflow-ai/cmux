import SwiftUI
import CmuxNextDesign

/// A small gray label.
struct AutomationChip: View {
    let text: String
    let palette: AutomationsPalette

    var body: some View {
        Text(text).font(palette.caption).foregroundStyle(palette.text)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Metrics.controlCornerRadius).fill(palette.hover))
    }
}
