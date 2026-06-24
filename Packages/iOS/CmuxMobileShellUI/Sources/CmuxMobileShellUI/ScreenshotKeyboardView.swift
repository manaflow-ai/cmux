#if canImport(UIKit) && DEBUG
import SwiftUI

/// A non-interactive, dependency-free dark-mode iOS software keyboard rendered
/// purely for App Store screenshots. It mimics the standard US QWERTY layout and
/// appearance but has no interactivity and holds no state.
struct ScreenshotKeyboardView: View {
    /// Total keyboard height to fill.
    var height: CGFloat

    private let bgColor = Color(red: 0.14, green: 0.14, blue: 0.16)
    private let letterColor = Color(red: 0.42, green: 0.43, blue: 0.46)
    private let specialColor = Color(red: 0.27, green: 0.28, blue: 0.31)

    private let sideMargin: CGFloat = 3
    private let keyGap: CGFloat = 6
    private let rowGap: CGFloat = 5

    private let row1 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private let row2 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private let row3 = ["z", "x", "c", "v", "b", "n", "m"]

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let usableWidth = totalWidth - sideMargin * 2
            // Base unit key width derived from the 10-key top row.
            let unit = (usableWidth - keyGap * 9) / 10
            let rowHeight = (height - rowGap * 3) / 4

            VStack(spacing: rowGap) {
                // Row 1
                HStack(spacing: keyGap) {
                    ForEach(row1, id: \.self) { key in
                        keyView(key, color: letterColor, width: unit, height: rowHeight)
                    }
                }

                // Row 2 (inset by half a key on each side).
                HStack(spacing: keyGap) {
                    ForEach(row2, id: \.self) { key in
                        keyView(key, color: letterColor, width: unit, height: rowHeight)
                    }
                }
                .padding(.horizontal, (unit + keyGap) / 2)

                // Row 3: shift, letters, delete.
                HStack(spacing: keyGap) {
                    keyView("⇧", color: specialColor, width: unit * 1.5, height: rowHeight, fontSize: 18)
                    ForEach(row3, id: \.self) { key in
                        keyView(key, color: letterColor, width: unit, height: rowHeight)
                    }
                    keyView("⌫", color: specialColor, width: unit * 1.5, height: rowHeight, fontSize: 18)
                }

                // Row 4: 123, globe, space, return.
                HStack(spacing: keyGap) {
                    keyView("123", color: specialColor, width: unit * 1.4, height: rowHeight, fontSize: 15)
                    keyView("🌐", color: specialColor, width: unit, height: rowHeight, fontSize: 18)
                    keyView("space", color: letterColor, width: 0, height: rowHeight, fontSize: 16)
                        .frame(maxWidth: .infinity)
                    keyView("return", color: specialColor, width: unit * 2.0, height: rowHeight, fontSize: 15)
                }
            }
            .padding(.horizontal, sideMargin)
            .frame(width: totalWidth, height: height, alignment: .top)
            .background(bgColor)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func keyView(
        _ label: String,
        color: Color,
        width: CGFloat,
        height: CGFloat,
        fontSize: CGFloat = 22
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let content = shape
            .fill(color)
            .overlay(
                Text(label)
                    .font(.system(size: fontSize, weight: .regular, design: .rounded))
                    .foregroundColor(.white)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 0, x: 0, y: 1)

        if width > 0 {
            content.frame(width: width, height: height)
        } else {
            content.frame(height: height)
        }
    }
}

#Preview {
    ScreenshotKeyboardView(height: 300)
        .frame(width: 393)
        .background(Color.black)
}
#endif
