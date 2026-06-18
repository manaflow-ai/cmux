import SwiftUI

/// Applies a foreground color only when one is resolved.
struct OptionalForeground: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

/// Applies uniform padding only when a value is provided.
struct OptionalPadding: ViewModifier {
    let padding: CGFloat?
    func body(content: Content) -> some View {
        if let padding { content.padding(padding) } else { content }
    }
}

/// Applies a rounded background fill only when a color is resolved.
struct OptionalBackground: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color {
            content.background(RoundedRectangle(cornerRadius: 6).fill(color))
        } else {
            content
        }
    }
}
