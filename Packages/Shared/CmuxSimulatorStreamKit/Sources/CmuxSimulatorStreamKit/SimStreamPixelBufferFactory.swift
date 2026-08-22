import Accelerate
import CoreVideo
import Foundation

public enum SimStreamPixelBufferError: Error, Equatable {
    case poolCreationFailed(CVReturn)
    case bufferCreationFailed(CVReturn)
    case geometryMismatch
    case scaleFailed(Int)
}



/// Pools BGRA pixel buffers and fills them from packed-BGRA frame bytes.
///
/// The copy here is the single unavoidable one between the simulator worker's
/// shared-memory ring and VideoToolbox (the ring's stable slots must never be
/// aliased by encoder-retained buffers). Pooling keeps it allocation-free in
/// steady state.
/// Checked `Sendable`: the pool cache must be reachable synchronously from
/// the encode path (an actor hop per frame would serialize pixel copies
/// behind unrelated actor work), so a private lock guards the three cache
/// fields instead of actor isolation. Every access is inside `pool(width:height:)`.
public final class SimStreamPixelBufferFactory: @unchecked Sendable {
    /// Encode dimensions for a source frame under a long-side cap, rounded to
    /// even values for codec friendliness. Pure so tests pin the math.
    public static func encodeSize(
        sourceWidth: Int, sourceHeight: Int, maximumLongSide: Int
    ) -> (width: Int, height: Int) {
        let longSide = max(sourceWidth, sourceHeight)
        var width = sourceWidth
        var height = sourceHeight
        if maximumLongSide > 0, longSide > maximumLongSide {
            let ratio = Double(maximumLongSide) / Double(longSide)
            width = Int((Double(sourceWidth) * ratio).rounded())
            height = Int((Double(sourceHeight) * ratio).rounded())
        }
        width = max(2, width & ~1)
        height = max(2, height & ~1)
        return (width, height)
    }

    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    public init() {}

    /// Fills a pooled BGRA buffer from packed-BGRA bytes, downscaling with
    /// vImage when the source's long side exceeds `maximumLongSide` (0 = no cap).
    public func makePixelBuffer(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        maximumLongSide: Int = 0
    ) throws -> CVPixelBuffer {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
            pixels.count >= bytesPerRow * height
        else {
            throw SimStreamPixelBufferError.geometryMismatch
        }
        let target = Self.encodeSize(
            sourceWidth: width, sourceHeight: height, maximumLongSide: maximumLongSide)
        if target.width != width || target.height != height {
            return try makeScaledPixelBuffer(
                pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow,
                targetWidth: target.width, targetHeight: target.height)
        }
        let pool = try pool(width: width, height: height)
        var buffer: CVPixelBuffer?
        let creation = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard creation == kCVReturnSuccess, let buffer else {
            throw SimStreamPixelBufferError.bufferCreationFailed(creation)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destinationBase = CVPixelBufferGetBaseAddress(buffer) else {
            throw SimStreamPixelBufferError.bufferCreationFailed(kCVReturnError)
        }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let rowByteCount = width * 4
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let sourceBase = source.baseAddress else { return }
            if destinationStride == bytesPerRow {
                memcpy(destinationBase, sourceBase, bytesPerRow * height)
            } else {
                for row in 0..<height {
                    memcpy(
                        destinationBase + row * destinationStride,
                        sourceBase + row * bytesPerRow,
                        rowByteCount
                    )
                }
            }
        }
        return buffer
    }

    private func makeScaledPixelBuffer(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> CVPixelBuffer {
        let pool = try pool(width: targetWidth, height: targetHeight)
        var buffer: CVPixelBuffer?
        let creation = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard creation == kCVReturnSuccess, let buffer else {
            throw SimStreamPixelBufferError.bufferCreationFailed(creation)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destinationBase = CVPixelBufferGetBaseAddress(buffer) else {
            throw SimStreamPixelBufferError.bufferCreationFailed(kCVReturnError)
        }
        var destination = vImage_Buffer(
            data: destinationBase,
            height: vImagePixelCount(targetHeight),
            width: vImagePixelCount(targetWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        let scaleError = pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> vImage_Error in
            guard let sourceBase = source.baseAddress else {
                return vImage_Error(kvImageInvalidParameter)
            }
            var sourceBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: sourceBase),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            return vImageScale_ARGB8888(
                &sourceBuffer, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard scaleError == kvImageNoError else {
            throw SimStreamPixelBufferError.scaleFailed(Int(scaleError))
        }
        return buffer
    }

    private func pool(width: Int, height: Int) throws -> CVPixelBufferPool {
        lock.lock()
        defer { lock.unlock() }
        if let pool, poolWidth == width, poolHeight == height {
            return pool
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBufferPool?
        let creation = CVPixelBufferPoolCreate(
            nil,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            attributes as CFDictionary,
            &created
        )
        guard creation == kCVReturnSuccess, let created else {
            throw SimStreamPixelBufferError.poolCreationFailed(creation)
        }
        pool = created
        poolWidth = width
        poolHeight = height
        return created
    }
}
