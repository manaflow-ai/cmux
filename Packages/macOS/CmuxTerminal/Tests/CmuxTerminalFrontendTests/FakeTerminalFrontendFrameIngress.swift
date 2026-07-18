import CmuxTerminalFrontend
import CmuxTerminalRenderCompositor
import CmuxTerminalRenderTransport

actor FakeTerminalFrontendFrameIngress: TerminalFrontendFrameIngress {
    func enqueue(
        _ frame: TerminalRenderFrame
    ) async -> TerminalRenderCompositorEnqueueResult {
        .metalUnavailable
    }
}
