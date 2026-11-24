import CoreVideo
import Foundation
import WebRTC

/// Converts software-decoded I420 into NV12; hardware-decoded frames keep their buffer.
/// One instance belongs to one libwebrtc renderer thread.
final class ScreenVideoPixels {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero

    /// The frame's pixels: the decoder's own buffer (hardware decode), else
    /// an I420 frame copied into a pooled NV12 buffer.
    func pixelBuffer(of frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let buffer = frame.buffer as? RTCCVPixelBuffer { return buffer.pixelBuffer }
        let i420 = frame.buffer.toI420()
        let width = Int(i420.width), height = Int(i420.height)
        if pool == nil || size != CGSize(width: width, height: height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            size = CGSize(width: width, height: height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        guard CVPixelBufferLockBaseAddress(out, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(out, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
            for row in 0 ..< height {
                memcpy(y + row * stride, i420.dataY + row * Int(i420.strideY), width)
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
            for row in 0 ..< (height + 1) / 2 {
                let u = i420.dataU + row * Int(i420.strideU), v = i420.dataV + row * Int(i420.strideV)
                let line = uv + row * stride
                for column in 0 ..< (width + 1) / 2 {
                    line[2 * column] = u[column]
                    line[2 * column + 1] = v[column]
                }
            }
        }
        return out
    }
}
