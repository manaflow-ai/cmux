import AppKit

@MainActor
final class PanelOwnedNativeViewSession<View: NSView> {
    private let makeView: @MainActor () -> View
    private let closeView: @MainActor (View) -> Void
    private let dismantleView: @MainActor (View) -> Void
    private var ownedView: View?
    private var retiredViews: Set<ObjectIdentifier> = []

    init(
        makeView: @escaping @MainActor () -> View,
        closeView: @escaping @MainActor (View) -> Void = { $0.removeFromSuperview() },
        dismantleView: (@MainActor (View) -> Void)? = nil
    ) {
        self.makeView = makeView
        self.closeView = closeView
        self.dismantleView = dismantleView ?? closeView
    }

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(configure: @MainActor (View) -> Void) -> View {
        let view = ownedView ?? makeView()
        retiredViews.remove(ObjectIdentifier(view))
        ownedView = view
        if view.superview != nil {
            view.removeFromSuperview()
        }
        configure(view)
        return view
    }

    func update(_ view: View, configure: @MainActor (View) -> Void) {
        guard !retiredViews.contains(ObjectIdentifier(view)) else { return }
        if ownedView == nil {
            ownedView = view
        }
        configure(view)
    }

    func close() {
        if let ownedView {
            retiredViews.insert(ObjectIdentifier(ownedView))
            closeView(ownedView)
        }
        ownedView = nil
    }

    func dismantle(_ view: View) {
        let viewId = ObjectIdentifier(view)
        guard !retiredViews.contains(viewId) else { return }
        retiredViews.insert(viewId)
        if ownedView === view {
            ownedView = nil
        }
        dismantleView(view)
    }
}
