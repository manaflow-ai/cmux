import SwiftUI

struct MobileToastTransitionEffect: ViewModifier {
    let opacity: Double
    let verticalOffset: CGFloat
    let scale: CGFloat
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: verticalOffset)
            .scaleEffect(scale, anchor: .top)
            .blur(radius: blurRadius)
    }
}

extension AnyTransition {
    static var mobileToast: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: MobileToastTransitionEffect(
                    opacity: 0,
                    verticalOffset: -14,
                    scale: 0.94,
                    blurRadius: 6
                ),
                identity: MobileToastTransitionEffect(
                    opacity: 1,
                    verticalOffset: 0,
                    scale: 1,
                    blurRadius: 0
                )
            ),
            removal: .modifier(
                active: MobileToastTransitionEffect(
                    opacity: 0,
                    verticalOffset: -8,
                    scale: 0.98,
                    blurRadius: 3
                ),
                identity: MobileToastTransitionEffect(
                    opacity: 1,
                    verticalOffset: 0,
                    scale: 1,
                    blurRadius: 0
                )
            )
        )
    }
}
