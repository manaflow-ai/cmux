import SwiftUI

/// Gray buttons: no accent color anywhere. `primary` is the theme's
/// foreground as a fill, `plain` a faint fill, `destructive` red text.
struct FeedButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case plain
        case destructive
        /// A selectable chip (choice options).
        case chip(selected: Bool)
    }

    var role: Role = .plain
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        FeedButtonBody(label: configuration.label, isPressed: configuration.isPressed, role: role, compact: compact)
    }
}

/// The button's look; a view so it can keep its hover state.
private struct FeedButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let role: FeedButtonStyle.Role
    let compact: Bool
    @Environment(\.feedColors) private var colors
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: compact ? 11 : 12, weight: weight))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: compact ? 22 : 26)
            .background(
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .fill(fill(pressed: isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var weight: Font.Weight {
        switch role {
        case .primary: .semibold
        case let .chip(selected): selected ? .semibold : .regular
        default: .medium
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: colors.onPrimary
        case .destructive: colors.danger
        case let .chip(selected): selected ? colors.primary : colors.secondary
        case .plain: colors.primary
        }
    }

    private func fill(pressed: Bool) -> Color {
        switch role {
        case .primary: colors.primary.opacity(pressed ? 0.75 : (hovering ? 0.9 : 1))
        case let .chip(selected): selected ? colors.selection : (pressed ? colors.pressed : (hovering ? colors.hover : .clear))
        default: pressed ? colors.pressed : (hovering ? colors.selection : colors.hover)
        }
    }

    private var stroke: Color {
        if case let .chip(selected) = role, !selected { return colors.borders ? colors.separator : colors.hover }
        return .clear
    }
}

/// A plain text field with the theme's faint fill and no focus ring color.
struct FeedTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @Environment(\.feedColors) private var colors

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(colors.primary)
            .tint(colors.primary)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(colors.hover))
            .onSubmit(onSubmit)
    }
}
