import AppKit
@testable import CmuxTerminal

@MainActor
final class FakeTerminalSurfacePaneHost: NSView, TerminalSurfacePaneHosting {
    private let surfaceView: FakeTerminalSurfaceNativeView
    private let attachesThroughSurfaceModel: Bool

    init(surfaceView: FakeTerminalSurfaceNativeView, attachesThroughSurfaceModel: Bool = false) {
        self.surfaceView = surfaceView
        self.attachesThroughSurfaceModel = attachesThroughSurfaceModel
        super.init(frame: surfaceView.frame)
        addSubview(surfaceView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable in tests")
    }

    func attachSurface(_ surface: TerminalSurface) {
        surfaceView.attachedController = surface
        if attachesThroughSurfaceModel {
            surface.attachToView(surfaceView)
        }
    }

    func cancelFocusRequest() {}
    func setVisibleInUI(_ visible: Bool) {}
    func setActive(_ active: Bool) {}
    func syncKeyStateIndicator(text: String?) {}
    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {}
}
