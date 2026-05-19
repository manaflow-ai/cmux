import AppKit

@MainActor
final class PanelOwnedNativeViewSession<View: NSView> {
    private let makeView: @MainActor () -> View
    private let closeView: @MainActor (View) -> Void
    private var ownedView: View?

    init(
        makeView: @escaping @MainActor () -> View,
        closeView: @escaping @MainActor (View) -> Void = { $0.removeFromSuperview() }
    ) {
        self.makeView = makeView
        self.closeView = closeView
    }

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(configure: @MainActor (View) -> Void) -> View {
        let view = ownedView ?? makeView()
        ownedView = view
        if view.superview != nil {
            view.removeFromSuperview()
        }
        configure(view)
        return view
    }

    func update(_ view: View, configure: @MainActor (View) -> Void) {
        if ownedView == nil {
            ownedView = view
        }
        configure(view)
    }

    func close() {
        if let ownedView {
            closeView(ownedView)
        }
        ownedView = nil
    }
}
