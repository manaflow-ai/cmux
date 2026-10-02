#if os(iOS)
import SwiftUI

struct MobilePrimarySearchTabBarVisibilityModifier: ViewModifier {
    let isEnabled: Bool
    let visibility: Visibility

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.mobileToolbarVisibility(visibility, for: .tabBar)
        } else {
            content
        }
    }
}
#endif
