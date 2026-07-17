import SwiftUI

struct MobileToastHostModifier: ViewModifier {
    let clock: any Clock<Duration>
    @State private var presenter = MobileToastPresenter()

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .overlay(alignment: .top) {
                MobileToastViewport(presenter: presenter, clock: clock)
                    .safeAreaPadding(.top, 52)
                    .padding(.horizontal, 12)
                    .zIndex(10_000)
            }
    }
}
