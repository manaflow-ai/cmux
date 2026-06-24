public import SwiftUI

/// A minimal horizontal stack that flows its children into multiple rows,
/// wrapping whenever the next child would overflow the available width.
///
/// `WrapHStack` is a thin, domain-free convenience wrapper around ``FlowLayout``:
/// it builds its content once via a `@ViewBuilder` closure and hands the result
/// to a `FlowLayout` configured with the same `spacing`. Use it where an
/// `HStack` would clip or push content offscreen and wrapping is preferred.
public struct WrapHStack<Content: View>: View {
    /// Horizontal gap between adjacent children, and vertical gap between rows.
    public let spacing: CGFloat

    /// Builds the children to flow into rows.
    public let content: () -> Content

    /// Creates a wrapping horizontal stack.
    /// - Parameters:
    ///   - spacing: The gap between adjacent children and between wrapped rows.
    ///   - content: A view builder producing the children to flow.
    public init(spacing: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        FlowLayout(spacing: spacing) {
            content()
        }
    }
}
