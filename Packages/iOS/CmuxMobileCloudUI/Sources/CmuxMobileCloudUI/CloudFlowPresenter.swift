#if os(iOS)
public import CmuxMobileCloud
public import SwiftUI

extension View {
    /// Hosts the full-screen Cloud flow. Apply on the stable container (the
    /// `NavigationStack`) of the screen that shows ``CloudEntryRow``; the row
    /// only flips ``CloudSessionController/isFlowPresented``.
    public func cloudFlowPresenter() -> some View {
        modifier(CloudFlowPresenter())
    }
}

private struct CloudFlowPresenter: ViewModifier {
    @Environment(\.cloudSessionController) private var controller

    func body(content: Content) -> some View {
        if let controller {
            content.fullScreenCover(isPresented: Binding(
                get: { controller.isFlowPresented },
                set: { controller.isFlowPresented = $0 }
            )) {
                CloudFlowView(controller: controller)
            }
        } else {
            content
        }
    }
}
#endif
