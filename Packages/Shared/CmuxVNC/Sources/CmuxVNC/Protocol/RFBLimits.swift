import Foundation

/// Bounds on what a server can make the client allocate. A VNC server is
/// untrusted input: without these a crafted ServerInit, DesktopSize, cursor
/// or compressed rectangle could exhaust memory.
struct RFBLimits {
    /// Largest framebuffer side (6K displays side by side fit).
    static let maxSide = 16384
    /// Largest framebuffer area in pixels (256 MB of BGRA).
    static let maxPixels = 64 << 20
    /// Largest cursor side.
    static let maxCursorSide = 256
    /// Largest Apple DH key, in bytes (Apple uses 128).
    static let maxDHKeyBytes = 512
    /// Largest compressed rectangle body.
    static let maxCompressedBytes = 64 << 20

    static func checkFramebuffer(width: Int, height: Int) throws {
        guard width >= 0, height >= 0, width <= maxSide, height <= maxSide, width * height <= maxPixels else {
            throw RFBError.protocolViolation("framebuffer \(width)x\(height) is too large")
        }
    }
}
