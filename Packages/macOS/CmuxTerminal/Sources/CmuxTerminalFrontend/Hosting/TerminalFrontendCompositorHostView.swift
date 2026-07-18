public import AppKit
public import CmuxTerminalDomain
public import CmuxTerminalRenderCompositor
public import CmuxTerminalRenderProtocol
public import CmuxTerminalRenderTransport

/// AppKit host for one authenticated out-of-process terminal compositor.
///
/// The view owns layout, focus placement, and frame presentation only. It has
/// no terminal parser, PTY, renderer pipeline, font atlas, or dynamic library
/// loader. A backend adapter owns input and canonical state outside this type.
@MainActor
public final class TerminalFrontendCompositorHostView: NSView {
    private let compositor: any TerminalFrontendCompositing

    /// The surface's participation in app focus routing.
    public var focusPlacement: TerminalSurfaceFocusPlacement

    /// Frame ingress used by the authenticated receiver without entering the main actor.
    public nonisolated let frameIngress: any TerminalFrontendFrameIngress

    /// The AppKit compositor view mounted edge-to-edge inside this host.
    public var compositorView: NSView {
        compositor
    }

    /// Creates a host around an injected compositor.
    ///
    /// - Parameters:
    ///   - compositor: The compositor that presents authenticated IOSurfaces.
    ///   - focusPlacement: The surface's initial focus-routing placement.
    public init(
        compositor: any TerminalFrontendCompositing,
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace
    ) {
        self.compositor = compositor
        self.frameIngress = compositor.frontendFrameIngress
        self.focusPlacement = focusPlacement
        super.init(frame: .zero)
        addSubview(compositor)
    }

    /// Creates a host and the production single-blit Metal compositor.
    ///
    /// - Parameters:
    ///   - fence: The exact renderer and presentation generation to accept.
    ///   - focusPlacement: The surface's initial focus-routing placement.
    ///   - frameReleaseHandler: Called once the IOSurface frame may be reused.
    /// - Throws: ``TerminalRenderCompositorError`` when Metal is unavailable.
    public convenience init(
        fence: TerminalRenderPresentationFence,
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        frameReleaseHandler: @escaping @Sendable (TerminalRenderFrameRelease) -> Void
    ) throws {
        let compositor = try TerminalRenderCompositorView(
            fence: fence,
            frameReleaseHandler: frameReleaseHandler
        )
        self.init(compositor: compositor, focusPlacement: focusPlacement)
    }

    @available(*, unavailable, message: "Construct with an authenticated compositor")
    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        compositor.frame = bounds
    }

    /// Atomically installs a newly authenticated renderer generation.
    ///
    /// - Parameter fence: The replacement presentation fence.
    public func updateFence(_ fence: TerminalRenderPresentationFence) {
        compositor.updateFence(fence)
    }

    /// Retires the compositor before detaching this frontend presentation.
    public func retire() {
        compositor.retire()
    }
}
