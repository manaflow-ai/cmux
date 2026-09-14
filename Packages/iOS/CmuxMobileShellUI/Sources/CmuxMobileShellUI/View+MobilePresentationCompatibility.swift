#if os(iOS)
import SwiftUI

extension View {
    /// Keeps the navigation bar and its top safe area on the same background.
    @ViewBuilder
    func mobileNavigationContainerBackground(_ color: Color) -> some View {
        if #available(iOS 18.0, *) {
            containerBackground(color, for: .navigation)
        } else {
            background(color.ignoresSafeArea(.container, edges: .top))
                .toolbarBackground(color, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// Uses native popover fitting on iOS 17 and explicit proposal sizing on newer systems.
    @ViewBuilder
    func mobileNoticePresentationSizing() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(AltScreenNoticePresentationSizing())
        } else {
            self
        }
    }

    @ViewBuilder
    func mobileToolbarVisibility(_ visibility: Visibility, for bar: ToolbarPlacement) -> some View {
        if #available(iOS 18.0, *) {
            toolbarVisibility(visibility, for: bar)
        } else {
            toolbar(visibility, for: bar)
        }
    }

    @ViewBuilder
    func mobileToolbarVisibility(
        _ visibility: Visibility,
        for firstBar: ToolbarPlacement,
        _ secondBar: ToolbarPlacement
    ) -> some View {
        if #available(iOS 18.0, *) {
            toolbarVisibility(visibility, for: firstBar, secondBar)
        } else {
            toolbar(visibility, for: firstBar, secondBar)
        }
    }
}
#endif
