import SwiftUI

/// A compact monochrome toggle for dense settings rows.
struct CompactGrayToggleStyle: ToggleStyle {
    private let width: CGFloat = 28
    private let height: CGFloat = 16
    private let knob: CGFloat = 12

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                configuration.isOn.toggle()
            }
        } label: {
            Capsule(style: .continuous)
                .fill(configuration.isOn
                    ? Color.secondary.opacity(0.78)
                    : Color.secondary.opacity(0.28))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.5)
                }
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white.opacity(0.96))
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                        .padding(2)
                }
                .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityValue(Text(configuration.isOn ? "1" : "0"))
    }
}
