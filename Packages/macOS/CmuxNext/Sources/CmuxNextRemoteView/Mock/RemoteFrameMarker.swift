import CoreVideo
import Foundation

/// The frame counter drawn as a bit pattern in the top-left of synthetic
/// frames (section 15.1 marker method): 16 data cells then a 1,0,1,0 guard,
/// each 32 x 32 pixels. A reader samples luma at each cell center, so the
/// counter survives lossy encode and decode.
nonisolated enum RemoteFrameMarker {
    static let cell = 32
    static let dataCells = 16
    static let totalCells = 20
    static let guardBits = [true, false, true, false]

    /// Draws `counter` into the Y plane of a locked NV12 buffer (full range).
    static func draw(_ counter: UInt16, y: UnsafeMutablePointer<UInt8>, yStride: Int) {
        for index in 0..<totalCells {
            let on = index < dataCells ? (counter >> UInt16(index)) & 1 == 1 : guardBits[index - dataCells]
            let x0 = index * cell
            for row in 0..<cell {
                (y + row * yStride + x0).update(repeating: on ? 255 : 0, count: cell)
            }
        }
    }

    /// Reads the counter from a decoded NV12 buffer; nil when the guard
    /// cells do not match (no marker, or a corrupted frame).
    static func read(_ buffer: CVPixelBuffer) -> UInt16? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferGetWidthOfPlane(buffer, 0) >= cell * totalCells,
              CVPixelBufferGetHeightOfPlane(buffer, 0) >= cell,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let threshold: UInt8 = fullRange ? 128 : 125
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let row = (cell / 2) * stride
        let bits = (0..<totalCells).map { luma[row + cell * $0 + cell / 2] > threshold }
        guard Array(bits[dataCells...]) == guardBits else { return nil }
        var value: UInt16 = 0
        for index in 0..<dataCells where bits[index] { value |= 1 << UInt16(index) }
        return value
    }
}
