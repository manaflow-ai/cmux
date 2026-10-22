public import AppKit
public import SwiftUI

/// Hosts a custom sidebar's scene (`cmux.sidebar/1`) scrolling in the sidebar's list frame, with
/// the sidebar's theme. A long list stays cheap when the script uses `LazyVStack`: only rows on
/// screen have views, and a batch re-renders only the nodes it touched (``AppSceneNodeSlot``).
public final class AppCustomSidebarHostingView: NSHostingView<AnyView> {
    private let sceneAppearance = AppSceneAppearance(useSidebarBackground: true)

    public init(model: AppSceneModel, bundleDirectory: URL?) {
        let root = AnyView(AppSceneThemedRoot(appearance: sceneAppearance) {
            ScrollView(.vertical) { AppSceneView(model: model, bundleDirectory: bundleDirectory) }
                .scrollIndicators(.automatic)
        })
        super.init(rootView: root)
        sizingOptions = []
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sceneAppearance.update(from: self)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sceneAppearance.update(from: self)
    }

    @available(*, unavailable)
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
