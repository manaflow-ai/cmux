#if os(iOS)
import SwiftUI

/// A horizontal scroll view's affordance: a 16 pt trailing fade while more content is
/// off screen to the right (code, tables, chips). Apply to the `ScrollView(.horizontal)`.
struct TrailingOverflowFade: ViewModifier {
    var width: CGFloat
    @State private var more = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
            } action: { _, overflow in
                if more != overflow { withAnimation(.easeOut(duration: 0.15)) { more = overflow } }
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, more ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                }
            }
    }
}

public extension View {
    /// See `TrailingOverflowFade`.
    func trailingOverflowFade(width: CGFloat = 16) -> some View {
        modifier(TrailingOverflowFade(width: width))
    }
}
#endif
