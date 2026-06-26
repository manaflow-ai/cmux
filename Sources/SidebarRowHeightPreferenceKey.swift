import SwiftUI

/// Publishes a sidebar row's measured height up to an ancestor so the value can
/// be consumed in `onPreferenceChange` — *after* the layout pass — instead of
/// being written into `@State` from inside a `GeometryReader` during layout.
///
/// Writing layout-derived `@State` mid-layout retriggers the SwiftUI
/// AttributeGraph and reproduces the `StackLayout.sizeThatFits` /
/// `ViewLayoutEngine.sizeThatFits` re-render livelock documented in
/// https://github.com/manaflow-ai/cmux/issues/2586 and
/// https://github.com/manaflow-ai/cmux/issues/6556. The measured height only
/// feeds drag/drop hit metrics, so reporting it through a preference keeps the
/// exact pointer-edge behavior while keeping the LazyVStack row free of
/// layout-pass state writes.
///
/// Shared by `SidebarWorkspaceGroupHeaderView` and `ContentView`'s
/// `TabItemView`; mirrors the existing `BrowserAddressBarHeightPreferenceKey`
/// pattern in `Sources/Panels/BrowserPanelView.swift`.
struct SidebarRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Measures this view's height and reports it through
    /// ``SidebarRowHeightPreferenceKey`` without writing `@State` during layout.
    /// Pair with `.onPreferenceChange(SidebarRowHeightPreferenceKey.self)`.
    func sidebarRowHeightProbe() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarRowHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }
}
