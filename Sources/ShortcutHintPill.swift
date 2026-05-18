import SwiftUI

enum ShortcutHintAnimation {
    static let visibility: Animation = .easeOut(duration: 0.12)
    static let transition: AnyTransition = .opacity
}

extension View {
    func shortcutHintTransition() -> some View {
        transition(ShortcutHintAnimation.transition)
    }

    func shortcutHintVisibilityAnimation<Value: Equatable>(value: Value) -> some View {
        animation(ShortcutHintAnimation.visibility, value: value)
    }
}

struct ShortcutHintPillBackground: View {
    var emphasis: Double = 1.0

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.30 * emphasis), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.22 * emphasis), radius: 2, x: 0, y: 1)
    }
}

/// Reusable shortcut hint pill that shows a keyboard shortcut string.
struct ShortcutHintPill: View {
    let text: String
    var fontSize: CGFloat = 9
    var emphasis: Double = 1.0

    init(shortcut: StoredShortcut, fontSize: CGFloat = 9, emphasis: Double = 1.0) {
        self.text = shortcut.displayString
        self.fontSize = fontSize
        self.emphasis = emphasis
    }

    init(text: String, fontSize: CGFloat = 9, emphasis: Double = 1.0) {
        self.text = text
        self.fontSize = fontSize
        self.emphasis = emphasis
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ShortcutHintPillBackground(emphasis: emphasis))
    }
}
