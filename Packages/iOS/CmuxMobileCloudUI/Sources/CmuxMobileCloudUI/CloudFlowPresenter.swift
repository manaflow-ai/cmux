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
            content.modifier(CloudFlowCover(controller: controller))
        } else {
            content
        }
    }
}

/// Split out so `@Bindable` produces a tracked binding: a hand-rolled
/// `Binding(get:set:)` over an observable property is read outside body
/// evaluation and never re-renders the cover.
private struct CloudFlowCover: ViewModifier {
    @Bindable var controller: CloudSessionController

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $controller.isFlowPresented) {
            CloudFlowView(controller: controller)
        }
    }
}
#endif
