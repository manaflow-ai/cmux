import UIKit

final class DisplayLinkProxy {
    private weak var target: GhosttySurfaceView?

    init(target: GhosttySurfaceView) {
        self.target = target
    }

    @objc func handleDisplayLink() {
        target?.handleDisplayLinkFire()
    }
}
