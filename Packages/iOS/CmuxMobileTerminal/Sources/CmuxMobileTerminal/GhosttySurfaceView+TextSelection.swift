#if canImport(UIKit)
import UIKit

extension GhosttySurfaceView {
    @objc func handleTextSelectionPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onTextSelectionRequested?()
    }
}
#endif
