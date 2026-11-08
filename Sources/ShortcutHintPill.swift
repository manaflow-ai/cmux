import AppKit
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

/// Cmd-hold hints fade both in and out, unlike other reveal chrome: the
/// whole hint layer appears at once across the window, and popping every
/// pill in the same frame reads as a flash. Matches Bonsplit's
/// `TabControlShortcutHintAnimation` so pane tab hints fade with the rest.
enum ShortcutHintAnimation {
    static let visibilityDuration: TimeInterval = 0.12
    static let fade: Animation = .easeOut(duration: visibilityDuration)
    static let transition: AnyTransition = .opacity

    /// The hint animation, or none under Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : fade
    }
}

private struct ShortcutHintVisibilityAnimationModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(ShortcutHintAnimation.animation(reduceMotion: reduceMotion), value: value)
    }
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
        modifier(ShortcutHintVisibilityAnimationModifier(value: isVisible))
    }
}

/// Colors every Cmd-hold shortcut hint uses: SwiftUI pills, the AppKit
/// sidebar pill, and (mirrored in vendor/bonsplit `TabControlShortcutHintStyle`)
/// pane tab hints.
///
/// Opaque, so contrast does not depend on what is behind the pill or on the
/// window appearance: 10.4:1 on dark chrome and 15.1:1 on light chrome.
/// The scheme comes from the chrome the pill sits on (the terminal-derived
/// scheme when the sidebar matches the terminal), never from a material that
/// resolves against the window.
enum ShortcutHintPalette {
    static func foreground(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
    }

    static func background(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    /// Width of the Liquid Glass rim around the opaque center on macOS 26.
    /// The glass takes its color from the backdrop and ignores a tint, so the
    /// text sits on the opaque ``background(for:)`` and keeps its contrast.
    static let glassRimWidth: CGFloat = 1.5

    static func border(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
    }
}

struct ShortcutHintPillBackground: View {
    var emphasis: Double = 1.0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        fill
            .shadow(color: Color.black.opacity(0.22 * emphasis), radius: 2, x: 0, y: 1)
    }

    /// A Liquid Glass rim around the opaque palette center where the OS has
    /// glass, the bordered opaque capsule before macOS 26.
    @ViewBuilder
    private var fill: some View {
        #if compiler(>=6.3)
        if #available(macOS 26.0, *) {
            ZStack {
                Color.clear
                    .glassEffect(.regular, in: Capsule(style: .continuous))
                Capsule(style: .continuous)
                    .inset(by: ShortcutHintPalette.glassRimWidth)
                    .fill(Color(nsColor: ShortcutHintPalette.background(for: colorScheme)))
            }
        } else {
            opaqueFill
        }
        #else
        opaqueFill
        #endif
    }

    private var opaqueFill: some View {
        Capsule(style: .continuous)
            .fill(Color(nsColor: ShortcutHintPalette.background(for: colorScheme)))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(nsColor: ShortcutHintPalette.border(for: colorScheme)), lineWidth: 0.8)
            )
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

    @Environment(\.colorScheme) private var colorScheme

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
            .foregroundColor(Color(nsColor: ShortcutHintPalette.foreground(for: colorScheme)))
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
