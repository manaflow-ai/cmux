public import SwiftUI
import CmuxFoundation

/// Sidebar shortcut-hint pill, package-local copy used by ``TabItemView``.
///
/// The app target keeps its own `ShortcutHintPill` (shared by group headers and
/// the right sidebar). This package copy lets the lifted workspace row render
/// the cmd-hold shortcut chip without reaching back into the app target, keeping
/// `TabItemView` free of app-target references.
struct TabItemShortcutHintPillBackground: View {
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

struct TabItemShortcutHintPill: View {
    let text: String
    var fontSize: CGFloat = 9
    var emphasis: Double = 1.0

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TabItemShortcutHintPillBackground(emphasis: emphasis))
    }
}

extension View {
    /// Top-trailing sidebar overlay for the workspace-row cmd-hold hint chip.
    /// Pass `text == nil` to render nothing. Mirrors the app's
    /// `sidebarShortcutHintOverlay` so the lifted row keeps identical placement.
    @ViewBuilder
    func tabItemShortcutHintOverlay(
        text: String?,
        emphasis: Double,
        offsetX: Double,
        offsetY: Double,
        fontSize: CGFloat = 10
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if let text {
                TabItemShortcutHintPill(text: text, fontSize: fontSize, emphasis: emphasis)
                    .offset(
                        x: ShortcutHintDebugSettings.clamped(offsetX),
                        y: ShortcutHintDebugSettings.clamped(offsetY)
                    )
                    .padding(.top, 6)
                    .padding(.trailing, 10)
                    .transition(.opacity)
            }
        }
    }

    func tabItemShortcutHintVisibilityAnimation<Value: Equatable>(value: Value) -> some View {
        animation(.easeOut(duration: 0.12), value: value)
    }
}
