public import CoreVideo

/// One captured page image. `CVPixelBuffer` is a reference to an immutable
/// IOSurface-backed image once the capturer hands it over, so sharing the
/// handle across actors is safe.
public struct BrowserCapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Host monotonic microseconds when the pixels were captured.
    public let captureMicros: UInt64

    public init(pixelBuffer: CVPixelBuffer, captureMicros: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.captureMicros = captureMicros
    }

    public var pixelWidth: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var pixelHeight: Int { CVPixelBufferGetHeight(pixelBuffer) }
}
