import AppKit
@testable import CmuxTerminal

@MainActor
final class FakeTerminalSurfacePaneHost: NSView, TerminalSurfacePaneHosting {
    private let surfaceView: FakeTerminalSurfaceNativeView
    private let attachesThroughSurfaceModel: Bool
    private let onAttach: (() -> Void)?
    private(set) var explicitInputCount = 0
    private(set) var runtimeSurfaceCreationFailureMessages: [String] = []
    private(set) var activeRuntimeSurfaceCreationFailureMessage: String?
    let runtimeSurfaceCreationFailures: AsyncStream<String>
    private let runtimeSurfaceCreationFailureContinuation:
        AsyncStream<String>.Continuation

    init(
        surfaceView: FakeTerminalSurfaceNativeView,
        attachesThroughSurfaceModel: Bool = false,
        onAttach: (() -> Void)? = nil
    ) {
        (runtimeSurfaceCreationFailures,
         runtimeSurfaceCreationFailureContinuation) =
            AsyncStream.makeStream(of: String.self)
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

    func showRuntimeSurfaceCreationFailure(message: String) {
        activeRuntimeSurfaceCreationFailureMessage = message
        runtimeSurfaceCreationFailureMessages.append(message)
        runtimeSurfaceCreationFailureContinuation.yield(message)
    }

    func clearRuntimeSurfaceCreationFailure() {
        activeRuntimeSurfaceCreationFailureMessage = nil
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        explicitInputCount += 1
    }
}
