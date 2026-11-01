import SwiftUI

/// A small gray label.
struct AutomationChip: View {
    let text: String
    let palette: AutomationsPalette

    var body: some View {
        Text(text).font(palette.caption).foregroundStyle(palette.text)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(palette.hover))
    }
}
