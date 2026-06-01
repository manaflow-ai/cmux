import SwiftUI

struct TitlebarInteractiveControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        TitlebarInteractiveControlHost {
            content
        }
    }
}

extension View {
    func titlebarInteractiveControl() -> some View {
        modifier(TitlebarInteractiveControlModifier())
    }
}
