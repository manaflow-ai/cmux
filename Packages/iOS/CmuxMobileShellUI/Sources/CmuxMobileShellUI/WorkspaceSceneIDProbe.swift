#if os(iOS)
import SwiftUI
@preconcurrency import UIKit

struct WorkspaceSceneIDProbe: UIViewRepresentable {
    @Binding var sceneID: ObjectIdentifier?

    func makeUIView(context: Context) -> WorkspaceSceneProbeView {
        WorkspaceSceneProbeView { sceneID = $0 }
    }

    func updateUIView(_ uiView: WorkspaceSceneProbeView, context: Context) {
        uiView.onSceneIDChange = { sceneID = $0 }
    }
}
#endif
