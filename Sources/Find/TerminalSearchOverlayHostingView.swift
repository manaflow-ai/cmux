import AppKit
import SwiftUI

final class TerminalSearchOverlayHostingView: NSHostingView<SurfaceSearchOverlay> {
    private weak var surfaceView: GhosttyNSView?

    init(rootView: SurfaceSearchOverlay, surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: SurfaceSearchOverlay) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDragged(with event: NSEvent) {
        guard surfaceView?.forwardPendingLeftMouseDrag(with: event) != true else { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard surfaceView?.completePendingLeftMouseRelease(with: event) != true else { return }
        super.mouseUp(with: event)
    }
}
