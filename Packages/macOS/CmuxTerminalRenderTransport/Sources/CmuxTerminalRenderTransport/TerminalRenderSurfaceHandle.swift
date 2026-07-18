public import IOSurface

/// A retained IOSurface that can cross Swift concurrency domains safely.
///
/// Safety: IOSurface objects are kernel-backed process-sharing handles. This
/// wrapper exposes immutable identity and descriptor reads only; pixel writes
/// and GPU synchronization remain the renderer's responsibility.
public final class TerminalRenderSurfaceHandle: @unchecked Sendable {
    let surface: IOSurfaceRef

    /// Creates a retained wrapper around an IOSurface.
    ///
    /// - Parameter surface: The kernel-backed IOSurface to transfer or present.
    public init(surface: IOSurfaceRef) {
        self.surface = surface
    }

    /// Kernel IOSurface identifier, stable across the transferred Mach right.
    public var identifier: UInt32 {
        IOSurfaceGetID(surface)
    }

    /// Current IOSurface width in pixels.
    public var width: Int {
        IOSurfaceGetWidth(surface)
    }

    /// Current IOSurface height in pixels.
    public var height: Int {
        IOSurfaceGetHeight(surface)
    }

    /// Current IOSurface pixel-format FourCC.
    public var pixelFormat: UInt32 {
        IOSurfaceGetPixelFormat(surface)
    }

    /// Borrows the retained IOSurface for Core Animation or Metal import.
    /// The reference remains valid for the duration of `body` and for the
    /// lifetime of this handle when retained by the receiving presentation.
    public func withIOSurface<Result>(
        _ body: (IOSurfaceRef) throws -> Result
    ) rethrows -> Result {
        try body(surface)
    }

    var bytesPerElement: Int {
        IOSurfaceGetBytesPerElement(surface)
    }

    var bytesPerRow: Int {
        IOSurfaceGetBytesPerRow(surface)
    }

    var allocationSize: Int {
        IOSurfaceGetAllocSize(surface)
    }

    var planeCount: Int {
        IOSurfaceGetPlaneCount(surface)
    }
}
