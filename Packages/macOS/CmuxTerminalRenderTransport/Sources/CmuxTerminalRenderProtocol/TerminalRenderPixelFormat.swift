/// Pixel layouts supported by the shared IOSurface frame plane.
public enum TerminalRenderPixelFormat: UInt32, CaseIterable, Sendable {
    /// Eight-bit normalized BGRA, represented by the IOSurface `BGRA` FourCC.
    case bgra8Unorm = 0x4247_5241

    /// Sixteen-bit floating-point RGBA, represented by the IOSurface `RGhA` FourCC.
    case rgba16Float = 0x5247_6841

    /// Required bytes per non-planar pixel for this format.
    public var bytesPerPixel: UInt32 {
        switch self {
        case .bgra8Unorm:
            4
        case .rgba16Float:
            8
        }
    }
}
