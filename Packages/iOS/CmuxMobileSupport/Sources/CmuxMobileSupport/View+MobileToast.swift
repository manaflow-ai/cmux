public import SwiftUI

public extension View {
    /// Installs one scene-local toast presenter and the shared top-edge viewport.
    ///
    /// Descendants present semantic toasts by reading ``MobileToastPresenter``
    /// from the SwiftUI environment.
    func mobileToastHost(
        clock: any Clock<Duration> = ContinuousClock()
    ) -> some View {
        modifier(MobileToastHostModifier(clock: clock))
    }
}
