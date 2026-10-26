import GhosttyNextKit

// What one terminal surface costs in memory, for the resource hover card and `debug.memory`.
extension TerminalSession {
    /// A rough app-side memory cost of the surface for the resource hover card: its drawable (three
    /// BGRA buffers) plus the GPU cell buffers (about 64 bytes per cell). Ghostty does not report its
    /// own allocations (font atlas, parser state), so this is a lower bound. Nil before attach or after free.
    public var memoryEstimateBytes: UInt64? {
        guard let surface = surfaceView.surface else { return nil }
        let size = ghostty_surface_size(surface)
        let cells = UInt64(size.columns) * UInt64(size.rows)
        return Self.drawableBytes(size) + cells * 64
    }

    /// The non-volatile IOSurface bytes the surface holds while it does not draw: its swap chain while
    /// it is GPU resident; 0 once it let that go, and 0 while it draws. Its presented frame is volatile
    /// while paused (``TerminalFramePurgeability``) and not counted.
    public var pausedNonvolatileIOSurfaceBytes: UInt64 {
        guard surfaceView.pause != nil, surfaceView.gpu.resident, let surface = surfaceView.surface else { return 0 }
        return Self.drawableBytes(ghostty_surface_size(surface))
    }

    private static func drawableBytes(_ size: ghostty_surface_size_s) -> UInt64 {
        UInt64(size.width_px) * UInt64(size.height_px) * 4 * 3
    }
}
