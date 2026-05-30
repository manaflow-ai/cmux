import SwiftUI

struct TitlebarInteractiveControlHost<Content: View>: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    private let rootView: Content

    init(@ViewBuilder content: () -> Content) {
        rootView = content()
    }

    func makeNSView(context: Context) -> TitlebarInteractiveHostingView<AnyView> {
        let view = TitlebarInteractiveHostingView(rootView: hostedRootView)
        view.identifier = TitlebarInteractiveHostingView<AnyView>.viewIdentifier
        return view
    }

    func updateNSView(_ nsView: TitlebarInteractiveHostingView<AnyView>, context: Context) {
        nsView.rootView = hostedRootView
        MinimalModeTitlebarControlHitRegionRegistry.register(nsView)
    }

    private var hostedRootView: AnyView {
        AnyView(rootView.environment(\.isEnabled, isEnabled))
    }
}
