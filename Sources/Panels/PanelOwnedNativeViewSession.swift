import AppKit

@MainActor
final class PanelOwnedNativeViewSession<View: NSView> {
    private let makeView: @MainActor () -> View
    private let closeView: @MainActor (View) -> Void
    private let dismantleView: @MainActor (View) -> Void
    private var ownedView: View?
    private var retiredViews: Set<ObjectIdentifier> = []
    private var dismantledViews: Set<ObjectIdentifier> = []

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
        let viewId = ObjectIdentifier(view)
        retiredViews.remove(viewId)
        dismantledViews.remove(viewId)
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

    @discardableResult
    func dismantle(_ view: View) -> Bool {
        let viewId = ObjectIdentifier(view)
        guard !dismantledViews.contains(viewId) else { return false }
        retiredViews.insert(viewId)
        dismantledViews.insert(viewId)
        let dismantledOwnedView = ownedView === view
        if dismantledOwnedView {
            ownedView = nil
        }
        dismantleView(view)
        return dismantledOwnedView
    }
}
