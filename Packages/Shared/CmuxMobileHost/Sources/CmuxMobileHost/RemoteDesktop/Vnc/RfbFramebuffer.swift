import CmuxRemoteDesktop
public import CoreVideo
import Foundation

/// The VNC server's framebuffer as BGRA bytes, updated by Raw, CopyRect and
/// DesktopSize rectangles, and copied out as IOSurface-backed pixel buffers.
public struct RfbFramebuffer: Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// Applies one rectangle; returns true when pixels or the size changed.
    @discardableResult
    public mutating func apply(_ rect: RfbRect) -> Bool {
        switch rect.content {
        case .desktopSize:
            self = RfbFramebuffer(width: rect.width, height: rect.height)
            return true
        case .raw(let data):
            guard rect.width > 0, rect.height > 0, rect.x + rect.width <= width, rect.y + rect.height <= height,
                  data.count == rect.width * rect.height * 4 else { return false }
            let rowBytes = rect.width * 4
            data.withUnsafeBytes { source in
                pixels.withUnsafeMutableBytes { target in
                    for row in 0..<rect.height {
                        let to = ((rect.y + row) * width + rect.x) * 4
                        target.baseAddress!.advanced(by: to).copyMemory(from: source.baseAddress!.advanced(by: row * rowBytes),
                                                                         byteCount: rowBytes)
                    }
                }
            }
            return true
        case .copy(let sx, let sy):
            guard rect.width > 0, rect.height > 0, rect.x + rect.width <= width, rect.y + rect.height <= height,
                  sx + rect.width <= width, sy + rect.height <= height else { return false }
            let rowBytes = rect.width * 4
            // Rows in the direction that never reads a row it already overwrote.
            let rows = sy < rect.y ? Array((0..<rect.height).reversed()) : Array(0..<rect.height)
            let stride = width * 4
            pixels.withUnsafeMutableBytes { buffer in
                for row in rows {
                    let from = (sy + row) * stride + sx * 4
                    let to = (rect.y + row) * stride + rect.x * 4
                    memmove(buffer.baseAddress!.advanced(by: to), buffer.baseAddress!.advanced(by: from), rowBytes)
                }
            }
            return true
        }
    }

    /// The BGRA pixels of `region` (clamped) in a new IOSurface-backed buffer.
    public func pixelBuffer(region: DesktopRect) -> CVPixelBuffer? {
        let x = max(0, min(region.x, width))
        let y = max(0, min(region.y, height))
        let w = max(0, min(region.width, width - x))
        let h = max(0, min(region.height, height - y))
        guard w > 0, h > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        pixels.withUnsafeBytes { source in
            for row in 0..<h {
                base.advanced(by: row * rowBytes).copyMemory(from: source.baseAddress!.advanced(by: ((y + row) * width + x) * 4),
                                                             byteCount: w * 4)
            }
        }
        return buffer
    }
}
