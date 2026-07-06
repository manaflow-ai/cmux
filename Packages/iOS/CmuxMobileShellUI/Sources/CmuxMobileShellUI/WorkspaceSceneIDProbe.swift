#if os(iOS)
import SwiftUI
@preconcurrency import UIKit

struct WorkspaceSceneIDProbe: UIViewRepresentable {
    @Binding var sceneID: ObjectIdentifier?

    func makeUIView(context: Context) -> SceneProbeView {
        SceneProbeView { sceneID = $0 }
    }

    func updateUIView(_ uiView: SceneProbeView, context: Context) {
        uiView.onSceneIDChange = { sceneID = $0 }
        uiView.reportSceneID()
    }

    final class SceneProbeView: UIView {
        var onSceneIDChange: (ObjectIdentifier?) -> Void

        init(onSceneIDChange: @escaping (ObjectIdentifier?) -> Void) {
            self.onSceneIDChange = onSceneIDChange
            super.init(frame: .zero)
            isHidden = true
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportSceneID()
        }

        func reportSceneID() {
            let id = window?.windowScene.map(ObjectIdentifier.init)
            Task { @MainActor in
                self.onSceneIDChange(id)
            }
        }
    }
}
#endif
