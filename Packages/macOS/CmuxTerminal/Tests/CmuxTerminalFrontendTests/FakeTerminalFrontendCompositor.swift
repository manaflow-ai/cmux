import AppKit
import CmuxTerminalFrontend
import CmuxTerminalRenderProtocol

@MainActor
final class FakeTerminalFrontendCompositor: NSView, TerminalFrontendCompositing {
    let frontendFrameIngress: any TerminalFrontendFrameIngress
    private(set) var installedFence: TerminalRenderPresentationFence
    private(set) var retired = false

    init(
        frameIngress: any TerminalFrontendFrameIngress,
        fence: TerminalRenderPresentationFence
    ) {
        self.frontendFrameIngress = frameIngress
        self.installedFence = fence
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updateFence(_ fence: TerminalRenderPresentationFence) {
        installedFence = fence
    }

    func retire() {
        retired = true
    }
}
