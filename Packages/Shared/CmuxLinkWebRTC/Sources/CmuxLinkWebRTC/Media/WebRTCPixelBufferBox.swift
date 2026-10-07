public import CoreVideo

/// A pixel buffer a publisher pushes as `MediaFrame.Payload.native`
/// (`CVPixelBuffer` is not `Sendable`; the publisher hands it over and does
/// not touch it again).
public struct WebRTCPixelBufferBox: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    public init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}
