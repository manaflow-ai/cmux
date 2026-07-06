#if os(iOS)
@preconcurrency import UIKit

final class WorkspaceSceneProbeView: UIView {
    var onSceneIDChange: (ObjectIdentifier?) -> Void
    private var reportedSceneID: ObjectIdentifier?

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
        guard id != reportedSceneID else { return }
        reportedSceneID = id
        onSceneIDChange(id)
    }
}
#endif
