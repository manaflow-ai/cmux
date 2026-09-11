import CmuxFoundation
import CmuxSettings
import SwiftUI

enum ShortcutHintAnimation {
    static let visibilityDuration: TimeInterval = 0.12
    static let visibility: Animation = .easeOut(duration: visibilityDuration)
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
    var style: SidebarShortcutHintStyle = .pill
    var textColor: Color?

    init(
        shortcut: StoredShortcut,
        fontSize: CGFloat = 9,
        emphasis: Double = 1.0,
        style: SidebarShortcutHintStyle = .pill,
        textColor: Color? = nil
    ) {
        self.text = shortcut.displayString
        self.fontSize = fontSize
        self.emphasis = emphasis
        self.style = style
        self.textColor = textColor
    }

    init(
        text: String,
        fontSize: CGFloat = 9,
        emphasis: Double = 1.0,
        style: SidebarShortcutHintStyle = .pill,
        textColor: Color? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.emphasis = emphasis
        self.style = style
        self.textColor = textColor
    }

    var body: some View {
        let label = Text(text)
            .cmuxFont(size: fontSize, weight: .semibold, design: .rounded)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(textColor ?? .primary)
        if style == .bare {
            label.padding(.vertical, 2)
        } else {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ShortcutHintPillBackground(emphasis: emphasis))
        }
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
        fontSize: CGFloat = 10,
        style: SidebarShortcutHintStyle = .pill,
        textColor: Color? = nil
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if let text {
                ShortcutHintPill(
                    text: text,
                    fontSize: fontSize,
                    emphasis: emphasis,
                    style: style,
                    textColor: textColor
                )
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
