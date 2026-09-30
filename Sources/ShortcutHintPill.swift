import CmuxFoundation
import SwiftUI

/// Motion for small chrome a heavy user summons many times an hour (hover
/// highlights, titlebar controls, shortcut hints): it appears in the same
/// frame and only fades when it goes away. Any hover or modifier-hold delay
/// is already the wait, so a fade-in only adds lag.
enum ChromeRevealAnimation {
    /// Animation for a visibility change to `isVisible`: none when showing or
    /// under Reduce Motion, `fadeOut` when hiding.
    static func animation(isVisible: Bool, fadeOut: Animation, reduceMotion: Bool) -> Animation? {
        isVisible || reduceMotion ? nil : fadeOut
    }
}

private struct ChromeRevealAnimationModifier: ViewModifier {
    let isVisible: Bool
    let fadeOut: Animation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(
            ChromeRevealAnimation.animation(isVisible: isVisible, fadeOut: fadeOut, reduceMotion: reduceMotion),
            value: isVisible
        )
    }
}

enum ShortcutHintAnimation {
    static let visibilityDuration: TimeInterval = 0.12
    static let fadeOut: Animation = .easeOut(duration: visibilityDuration)
    static let transition: AnyTransition = .asymmetric(insertion: .identity, removal: .opacity)
}

extension View {
    /// Shows chrome instantly and fades it out; see `ChromeRevealAnimation`.
    func chromeRevealAnimation(isVisible: Bool, fadeOut: Animation) -> some View {
        modifier(ChromeRevealAnimationModifier(isVisible: isVisible, fadeOut: fadeOut))
    }

    func shortcutHintTransition() -> some View {
        transition(ShortcutHintAnimation.transition)
    }

    func shortcutHintVisibilityAnimation(value isVisible: Bool) -> some View {
        chromeRevealAnimation(isVisible: isVisible, fadeOut: ShortcutHintAnimation.fadeOut)
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
            .cmuxFont(size: fontSize, weight: .semibold, design: .rounded)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ShortcutHintPillBackground(emphasis: emphasis))
    }
}

/// Standard top-trailing sidebar overlay used by every cmd-hold hint chip
/// in the sidebar (workspace rows, group headers, etc.) so they share font
/// size, padding, transition, and emphasis settings. Pass `text == nil` to
/// render nothing.
extension View {
    @ViewBuilder
    func sidebarShortcutHintOverlay(
        text: String?,
        emphasis: Double,
        offsetX: Double,
        offsetY: Double,
        fontSize: CGFloat = 10
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if let text {
                ShortcutHintPill(text: text, fontSize: fontSize, emphasis: emphasis)
                    .offset(
                        x: ShortcutHintDebugSettings.clamped(offsetX),
                        y: ShortcutHintDebugSettings.clamped(offsetY)
                    )
                    .padding(.top, 6)
                    .padding(.trailing, 10)
                    .shortcutHintTransition()
            }
        }
    }
}
