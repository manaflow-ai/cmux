import SwiftUI

struct RightSidebarContentTextStyle {
    let colorScheme: ColorScheme

    var primary: Color {
        .primary
    }

    var prominent: Color {
        colorScheme == .dark ? .primary : .primary.opacity(0.92)
    }

    func emphasized(lightOpacity: Double) -> Color {
        colorScheme == .dark ? .primary : .primary.opacity(lightOpacity)
    }

    var secondary: Color {
        colorScheme == .dark ? .primary.opacity(0.76) : .secondary
    }

    var tertiary: Color {
        colorScheme == .dark ? .primary.opacity(0.66) : .secondary.opacity(0.7)
    }

    var quaternary: Color {
        colorScheme == .dark ? .primary.opacity(0.56) : .secondary.opacity(0.5)
    }
}
