#if canImport(UIKit)
import CmuxMobileSupport
import SwiftUI

struct BrowserStreamDialogButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if prominent {
            content.mobileGlassProminentButton()
        } else {
            content.mobileGlassButton()
        }
    }
}
#endif
