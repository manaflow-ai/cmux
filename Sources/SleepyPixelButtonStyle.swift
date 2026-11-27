import SwiftUI

/// Big chunky pixel-art button: square corners, a raised bevel (light top/left,
/// dark bottom/right) that inverts and sinks on press, and a hard offset shadow.
struct SleepyPixelButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 16, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 22)
            .background(tint.opacity(pressed ? 1.0 : 0.85))
            .overlay(alignment: .top) { bar(pressed ? .black.opacity(0.35) : .white.opacity(0.4), height: 3) }
            .overlay(alignment: .leading) { bar(pressed ? .black.opacity(0.35) : .white.opacity(0.4), width: 3) }
            .overlay(alignment: .bottom) { bar(pressed ? .white.opacity(0.3) : .black.opacity(0.5), height: 3) }
            .overlay(alignment: .trailing) { bar(pressed ? .white.opacity(0.3) : .black.opacity(0.5), width: 3) }
            .overlay(Rectangle().strokeBorder(.black.opacity(0.55), lineWidth: 2))
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: pressed ? 1 : 4)
            .offset(y: pressed ? 2 : 0)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private func bar(_ color: Color, width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        Rectangle().fill(color).frame(width: width, height: height)
    }
}
