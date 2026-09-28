internal import Foundation

/// The crop and output size every frame of one recording uses.
///
/// A video has one frame size for its whole length, so the geometry is decided
/// once from the first captured frame and reused: a window resized mid-clip is
/// letterboxed into the size the clip started with rather than ending it.
public struct WindowRecordingFrameGeometry: Equatable, Sendable {
    /// Crop rectangle in captured pixels, origin at the image's top-left.
    public let cropX: Int
    public let cropY: Int
    public let cropWidth: Int
    public let cropHeight: Int
    /// Encoded frame size in pixels.
    public let outputWidth: Int
    public let outputHeight: Int

    public enum Failure: Error, Equatable, Sendable {
        case emptyWindow
        case regionOutsideWindow

        public var message: String {
            switch self {
            case .emptyWindow:
                "the window has no capturable content"
            case .regionOutsideWindow:
                "region lies outside the window"
            }
        }
    }

    public var cropsNothing: Bool {
        cropX == 0 && cropY == 0
    }

    public var scalesNothing: Bool {
        outputWidth == cropWidth && outputHeight == cropHeight
    }

    /// Plans the geometry from the first captured frame.
    ///
    /// - Parameters:
    ///   - windowPixelWidth: width of the captured window image, in pixels.
    ///   - windowPixelHeight: height of the captured window image, in pixels.
    ///   - pointPixelScale: pixels per point of the captured image, so a region
    ///     given in window points lands on the right pixels on a Retina display.
    ///   - request: the validated recording request.
    public static func plan(
        windowPixelWidth: Int,
        windowPixelHeight: Int,
        pointPixelScale: Double,
        request: WindowRecordingRequest
    ) throws -> WindowRecordingFrameGeometry {
        guard windowPixelWidth > 0, windowPixelHeight > 0 else {
            throw Failure.emptyWindow
        }
        let pixelScale = pointPixelScale.isFinite && pointPixelScale > 0 ? pointPixelScale : 1

        var cropX = 0
        var cropY = 0
        var cropWidth = windowPixelWidth
        var cropHeight = windowPixelHeight

        if case let .region(region) = request.target {
            let left = Int((region.x * pixelScale).rounded(.down))
            let top = Int((region.y * pixelScale).rounded(.down))
            let right = Int(((region.x + region.width) * pixelScale).rounded(.up))
            let bottom = Int(((region.y + region.height) * pixelScale).rounded(.up))
            cropX = max(0, min(left, windowPixelWidth))
            cropY = max(0, min(top, windowPixelHeight))
            cropWidth = min(right, windowPixelWidth) - cropX
            cropHeight = min(bottom, windowPixelHeight) - cropY
            guard cropWidth > 0, cropHeight > 0 else {
                throw Failure.regionOutsideWindow
            }
        }

        var outputWidth = Double(cropWidth) * request.scale
        var outputHeight = Double(cropHeight) * request.scale
        if let maximumWidth = request.maximumWidth, outputWidth > Double(maximumWidth) {
            let shrink = Double(maximumWidth) / outputWidth
            outputWidth *= shrink
            outputHeight *= shrink
        }

        let quantum = request.format == .mp4 ? 2 : 1
        return WindowRecordingFrameGeometry(
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            outputWidth: quantize(outputWidth, to: quantum),
            outputHeight: quantize(outputHeight, to: quantum)
        )
    }

    /// Keeps this geometry's encoded frame size while taking another plan's crop.
    ///
    /// A window resized mid-recording has to be cropped against the image that
    /// was captured, but the encoded frame size may not change, so the new crop
    /// is drawn into the size the clip started with.
    public func adoptingCrop(
        of other: WindowRecordingFrameGeometry
    ) -> WindowRecordingFrameGeometry {
        WindowRecordingFrameGeometry(
            cropX: other.cropX,
            cropY: other.cropY,
            cropWidth: other.cropWidth,
            cropHeight: other.cropHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
    }

    /// H.264 wants even dimensions; a gif only wants a positive one.
    private static func quantize(_ value: Double, to quantum: Int) -> Int {
        let rounded = max(quantum, Int(value.rounded()))
        return rounded - (rounded % quantum)
    }
}
