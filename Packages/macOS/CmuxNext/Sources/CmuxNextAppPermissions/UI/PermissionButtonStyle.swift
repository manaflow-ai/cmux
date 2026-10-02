import SwiftUI

/// Buttons: primary is a text-colored fill, quiet is text only.
struct PermissionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind
    @Environment(\.permissionColors) private var colors

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(kind == .primary ? colors.emphasized : colors.body)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet || kind == .danger ? 4 : 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: colors.onPrimary
        case .secondary, .quiet: colors.text
        case .danger: colors.danger
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: colors.text
        case .secondary: colors.field
        case .quiet, .danger: .clear
        }
    }
}
