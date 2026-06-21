import SwiftUI

private struct SidebarWorkspaceRowDropHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct SidebarWorkspaceRowDropHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SidebarWorkspaceRowDropHeightPreferenceKey.self,
                value: max(
                    SidebarWorkspaceRowDropMetrics.minimumTargetHeight,
                    proxy.size.height.rounded(.up)
                )
            )
        }
    }
}

private struct SidebarWorkspaceRowDropHeightMeasurementModifier: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                SidebarWorkspaceRowDropHeightReader()
            }
            .onPreferenceChange(SidebarWorkspaceRowDropHeightPreferenceKey.self) { nextHeight in
                guard let nextHeight, abs(height - nextHeight) >= 0.5 else { return }
                height = nextHeight
            }
    }
}

extension View {
    func sidebarWorkspaceRowDropHeight(_ height: Binding<CGFloat>) -> some View {
        modifier(SidebarWorkspaceRowDropHeightMeasurementModifier(height: height))
    }
}
