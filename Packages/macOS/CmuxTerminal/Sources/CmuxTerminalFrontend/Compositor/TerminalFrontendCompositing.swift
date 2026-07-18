public import AppKit
public import CmuxTerminalRenderProtocol

/// The authenticated IOSurface compositor hosted by a terminal frontend view.
@MainActor
public protocol TerminalFrontendCompositing: NSView {
    /// Frame ingress that receives authenticated renderer-worker frames off the main actor.
    var frontendFrameIngress: any TerminalFrontendFrameIngress { get }

    /// Replaces the exact renderer and presentation generation accepted by the compositor.
    ///
    /// - Parameter fence: The newly authenticated presentation fence.
    func updateFence(_ fence: TerminalRenderPresentationFence)

    /// Permanently rejects later frames and releases pending compositor work.
    func retire()
}
