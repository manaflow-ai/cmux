public import CmuxTerminalRenderCompositor

extension TerminalRenderCompositorView: TerminalFrontendCompositing {
    /// Frame ingress exposed through the frontend's dependency-inverted seam.
    public var frontendFrameIngress: any TerminalFrontendFrameIngress {
        frameIngress
    }
}
