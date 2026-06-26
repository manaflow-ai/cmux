public import SwiftUI

/// A horizontal stack that wraps its children onto additional rows when they no longer
/// fit the available width.
///
/// Children are laid out by ``FlowLayout`` using the same ``spacing`` between items and
/// between wrapped rows.
public struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    /// Creates a wrapping horizontal stack.
    /// - Parameters:
    ///   - spacing: The gap between items within a row and between wrapped rows.
    ///   - content: The child views to flow.
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
