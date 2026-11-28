public import AppKit
import SwiftUI

extension AppStoreModel {
    /// The App Store content as one self-contained view, hosted by its tab
    /// or top page (S22: the App Store has no window of its own).
    /// `inPane`: hosted in a pane (internal page tab): no traffic-light inset.
    public func makeContentView(inPane: Bool = false) -> NSView {
        AppStoreContentView(model: self, inPane: inPane)
    }
}

/// The App Store content: one self-contained view that resolves the scene
/// colors in its window's theme scope.
final class AppStoreContentView: NSHostingView<AnyView> {
    private let appearanceModel = AppSceneAppearance()

    init(model: AppStoreModel, inPane: Bool = false) {
        let appearance = appearanceModel
        super.init(rootView: AnyView(AppSceneThemedRoot(appearance: appearance) { AppStoreRootView(model: model, inPane: inPane) }))
    }

    @available(*, unavailable)
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    func resolveColors() {
        // The window background is its kind's (`NSWindow.install`).
        appearanceModel.update(from: self)
    }
}
