import AppKit
@testable import CmuxTerminal
import CmuxTerminalCore

@MainActor
final class FakeTerminalSurfacePaneHost: NSView, TerminalSurfacePaneHosting {
    private let surfaceView: FakeTerminalSurfaceNativeView
    private let attachesThroughSurfaceModel: Bool
    private let onAttach: (() -> Void)?
    private(set) var explicitInputCount = 0
    private(set) var terminalOverlays: [TerminalOverlay] = []
    var capturedTerminalOverlayAnchor: TerminalOverlayAnchor?

    init(
        surfaceView: FakeTerminalSurfaceNativeView,
        attachesThroughSurfaceModel: Bool = false,
        onAttach: (() -> Void)? = nil
    ) {
        self.surfaceView = surfaceView
        self.attachesThroughSurfaceModel = attachesThroughSurfaceModel
        self.onAttach = onAttach
        super.init(frame: surfaceView.frame)
        addSubview(surfaceView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable in tests")
    }

    func attachSurface(_ surface: TerminalSurface) {
        onAttach?()
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

    func captureTerminalOverlayScrollbackAnchor(
        sticksToViewportTop: Bool
    ) -> TerminalOverlayAnchor? {
        guard let anchor = capturedTerminalOverlayAnchor else { return nil }
        guard case .scrollback(let row, let revision, _) = anchor else { return anchor }
        return .scrollback(
            row: row,
            rowSpaceRevision: revision,
            sticksToViewportTop: sticksToViewportTop
        )
    }

    func setTerminalOverlays(_ overlays: [TerminalOverlay]) {
        terminalOverlays = overlays
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        explicitInputCount += 1
    }
}
