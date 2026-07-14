import SwiftUI

/// Reports a lazy sidebar row's frame as value data through parent-owned closures.
struct SidebarPointerFrameReportingModifier: ViewModifier {
    let onFrameChange: (CGRect) -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(SidebarPointerInteractionMonitor.coordinateSpaceName))
            } action: { frame in
                onFrameChange(frame)
            }
            .onDisappear(perform: onDisappear)
    }
}

extension View {
    func sidebarPointerFrameReporting(
        onFrameChange: @escaping (CGRect) -> Void,
        onDisappear: @escaping () -> Void
    ) -> some View {
        modifier(SidebarPointerFrameReportingModifier(
            onFrameChange: onFrameChange,
            onDisappear: onDisappear
        ))
    }
}
