#if os(iOS) && DEBUG
import CmuxMobileShell
import SwiftUI
import UIKit

/// A zero-size SwiftUI host that installs the floating dogfood pane window onto
/// the current `UIWindowScene` once it is connected.
///
/// Mounted in the root view's background. It resolves the scene in
/// `didMoveToWindow` (the scene is not connected at app launch, so resolving it
/// eagerly would fail), then builds and retains a ``DogfoodPaneWindowController``
/// — which puts the passthrough overlay window above the app. Retaining the
/// controller in the coordinator keeps the window alive.
///
/// DEBUG-only; absent in release builds.
struct DogfoodPaneInstaller: UIViewRepresentable {
    let model: DogfoodFeedbackModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> SceneResolvingView {
        let view = SceneResolvingView()
        view.onResolveScene = { [coordinator = context.coordinator] scene in
            coordinator.installIfNeeded(scene: scene)
        }
        return view
    }

    func updateUIView(_ uiView: SceneResolvingView, context: Context) {}

    /// Retains the overlay window controller across SwiftUI view updates.
    @MainActor
    final class Coordinator {
        private let model: DogfoodFeedbackModel
        private var controller: DogfoodPaneWindowController?

        init(model: DogfoodFeedbackModel) {
            self.model = model
        }

        func installIfNeeded(scene: UIWindowScene) {
            guard controller == nil else { return }
            controller = DogfoodPaneWindowController(scene: scene, model: model)
        }
    }

    /// A 0-size `UIView` that reports its window scene as soon as it is added to a
    /// window, so the overlay window can be created against the connected scene.
    final class SceneResolvingView: UIView {
        var onResolveScene: ((UIWindowScene) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                onResolveScene?(scene)
            }
        }
    }
}
#endif
