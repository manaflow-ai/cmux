import CmuxNextDesign
import GhosttyNextKit

// What one terminal surface costs in memory, for the resource hover card and `debug.memory`.
extension TerminalSession {
    /// A rough app-side memory cost of the surface for the resource hover card: its drawable (three
    /// BGRA buffers) plus the GPU cell buffers (about 64 bytes per cell). Ghostty does not report its
    /// own allocations (font atlas, parser state), so this is a lower bound. Nil before attach or after free.
    public var memoryEstimateBytes: UInt64? {
        guard let surface = surfaceView.surface else { return nil }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        let size = unsafe ghostty_surface_size(surface)
        let cells = UInt64(size.columns) * UInt64(size.rows)
        return Self.drawableBytes(size) + cells * 64
    }

    /// The estimated non-volatile IOSurface bytes the surface holds while it does not draw: the swap
    /// chain's two buffers besides the presented frame while it is GPU resident; 0 once it let them
    /// go, and 0 while it draws. The presented frame is volatile while paused
    /// (``TerminalFramePurgeability``) and not counted.
    public var pausedNonvolatileIOSurfaceBytes: UInt64 {
        guard surfaceView.pause != nil, surfaceView.gpu.resident, let surface = surfaceView.surface else { return 0 }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        return Self.drawableBytes(unsafe ghostty_surface_size(surface), buffers: Self.swapChainBuffers - 1)
    }

    /// Whether the surface is shown in a window that is off screen (minimized, another Space, covered):
    /// hidden from the person though not away from its pane (``TerminalOffScreenRelease``).
    public var isInOffScreenWindow: Bool { surfaceView.isShown && surfaceView.pause == .windowOccluded }

    /// Ghostty's swap chain: three BGRA buffers per surface.
    static let swapChainBuffers: UInt64 = 3

    static func drawableBytes(_ size: ghostty_surface_size_s, buffers: UInt64 = swapChainBuffers) -> UInt64 {
        UInt64(size.width_px) * UInt64(size.height_px) * 4 * buffers
    }
}
