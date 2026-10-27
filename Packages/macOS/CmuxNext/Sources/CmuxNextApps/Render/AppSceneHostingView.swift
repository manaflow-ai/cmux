public import AppKit
public import SwiftUI

/// An `NSHostingView` around `AppSceneView` for AppKit hosts (the sidebar
/// section provider wants an `NSView` plus a height for a width). An app's
/// page tab puts it in a `VisibilityGatedHostingView` (`AppPanePage`).
// hosting-gate: opt-out in the sidebar: a section shows while the sidebar does, and the sidebar measures it by intrinsic size.
public final class AppSceneHostingView: NSHostingView<AnyView> {
    public let model: AppSceneModel
    private let sceneAppearance = AppSceneAppearance(useSidebarBackground: true)
    /// Measures heights for a width without laying out this view.
    private let measurer: NSHostingController<AnyView>

    public init(model: AppSceneModel, bundleDirectory: URL?, bundleImages: AppBundleImageCache) {
        self.model = model
        let root = AnyView(AppSceneThemedRoot(appearance: sceneAppearance) {
            AppSceneView(model: model, bundleDirectory: bundleDirectory, bundleImages: bundleImages)
        })
        measurer = NSHostingController(rootView: root)
        super.init(rootView: root)
        sizingOptions = [.intrinsicContentSize]
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sceneAppearance.update(from: self)
    }

    // visibility-walk-allow: resolves the scene's theme colors and writes them only when they change; an app page's copy
    // sits in a VisibilityGatedHostingView, which holds SwiftUI's update while hidden, and a section shows with its sidebar
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sceneAppearance.update(from: self)
    }

    @available(*, unavailable)
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The scene's height when laid out `width` points wide.
    public func preferredHeight(width: CGFloat) -> CGFloat {
        let size = measurer.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }
}
