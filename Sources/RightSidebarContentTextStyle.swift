import SwiftUI

enum RightSidebarContentTextStyle {
    static func primary(colorScheme _: ColorScheme) -> Color {
        .primary
    }

    static func prominent(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .primary : .primary.opacity(0.92)
    }

    static func emphasized(colorScheme: ColorScheme, lightOpacity: Double) -> Color {
        colorScheme == .dark ? .primary : .primary.opacity(lightOpacity)
    }

    static func secondary(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .primary.opacity(0.76) : .secondary
    }

    static func tertiary(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .primary.opacity(0.66) : .secondary.opacity(0.7)
    }

    static func quaternary(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .primary.opacity(0.56) : .secondary.opacity(0.5)
    }
}
