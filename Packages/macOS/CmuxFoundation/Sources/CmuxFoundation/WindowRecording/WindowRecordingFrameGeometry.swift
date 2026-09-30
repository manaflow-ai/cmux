internal import Foundation

/// The crop and output size every frame of one recording uses.
///
/// A video has one frame size for its whole length, so the geometry is decided
/// once from the first captured frame and reused: a window resized mid-clip is
/// letterboxed into the size the clip started with rather than ending it. The
/// crop is planned again per frame, so a `region` that a shrinking window no
/// longer contains is the one resize that does end a clip.
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
        case gifFrameTooLarge

        public var message: String {
            switch self {
            case .emptyWindow:
                "the window has no capturable content"
            case .regionOutsideWindow:
                "region lies outside the window"
            case .gifFrameTooLarge:
                "gif frame exceeds the pixel limit"
            }
        }
    }

    /// Whether the crop keeps every pixel of a source of this size.
    public func cropsNothing(ofWidth sourceWidth: Int, height sourceHeight: Int) -> Bool {
        cropX == 0 && cropY == 0 && cropWidth == sourceWidth && cropHeight == sourceHeight
    }

    public var scalesNothing: Bool {
        outputWidth == cropWidth && outputHeight == cropHeight
    }

    /// Converts a pixel edge without relying on trapping `Int(Double)`.
    /// Infinite results arise legitimately when two finite region values or a
    /// finite coordinate and scale overflow; their clipped edge is still
    /// unambiguous. NaN has no such ordering and is rejected.
    private static func pixelIndex(
        _ value: Double,
        rounding rule: FloatingPointRoundingRule
    ) -> Int? {
        guard !value.isNaN else { return nil }
        let rounded = value.rounded(rule)
        if let exact = Int(exactly: rounded) {
            return exact
        }
        return rounded.sign == .minus ? Int.min : Int.max
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
        try plan(
            windowPixelWidth: windowPixelWidth,
            windowPixelHeight: windowPixelHeight,
            pointPixelScale: pointPixelScale,
            region: {
                if case let .region(region) = request.target { return region }
                return nil
            }(),
            scale: request.scale,
            maximumWidth: request.maximumWidth,
            widthQuantum: request.format == .mp4 ? 2 : 1,
            maximumPixels: request.format == .gif
                ? WindowRecordingRequest.gifMaximumPixelsPerFrame
                : nil
        )
    }

    /// Plans the geometry for one captured image.
    ///
    /// A still shares this with a recording so that `cmux shot --region` and
    /// `cmux record --region` crop the same pixels for the same numbers.
    ///
    /// - Parameters:
    ///   - windowPixelWidth: width of the captured window image, in pixels.
    ///   - windowPixelHeight: height of the captured window image, in pixels.
    ///   - pointPixelScale: pixels per point of the captured image, so a region
    ///     given in window points lands on the right pixels on a Retina display.
    ///   - region: the rectangle to crop to, in window points, or nil for the
    ///     whole window.
    ///   - scale: output size as a fraction of the cropped size.
    ///   - maximumWidth: cap on the output width in pixels, applied after `scale`.
    ///   - widthQuantum: the multiple both output dimensions are rounded down to.
    ///     H.264 wants 2; a still or a gif wants 1.
    ///   - maximumPixels: optional encoded-pixel limit, used to keep GIF staging bounded.
    public static func plan(
        windowPixelWidth: Int,
        windowPixelHeight: Int,
        pointPixelScale: Double,
        region: WindowRecordingRegion?,
        scale: Double,
        maximumWidth: Int?,
        widthQuantum: Int,
        maximumPixels: Int? = nil
    ) throws -> WindowRecordingFrameGeometry {
        guard windowPixelWidth > 0, windowPixelHeight > 0 else {
            throw Failure.emptyWindow
        }
        let pixelScale = pointPixelScale.isFinite && pointPixelScale > 0 ? pointPixelScale : 1

        var cropX = 0
        var cropY = 0
        var cropWidth = windowPixelWidth
        var cropHeight = windowPixelHeight

        if let region {
            guard region.isFinite,
                  region.width > 0,
                  region.height > 0,
                  let left = Self.pixelIndex(region.x * pixelScale, rounding: .down),
                  let top = Self.pixelIndex(region.y * pixelScale, rounding: .down),
                  let right = Self.pixelIndex(
                      (region.x + region.width) * pixelScale,
                      rounding: .up
                  ),
                  let bottom = Self.pixelIndex(
                      (region.y + region.height) * pixelScale,
                      rounding: .up
                  ) else {
                throw Failure.regionOutsideWindow
            }
            cropX = max(0, min(left, windowPixelWidth))
            cropY = max(0, min(top, windowPixelHeight))
            cropWidth = min(right, windowPixelWidth) - cropX
            cropHeight = min(bottom, windowPixelHeight) - cropY
            guard cropWidth > 0, cropHeight > 0 else {
                throw Failure.regionOutsideWindow
            }
        }

        var outputWidth = Double(cropWidth) * scale
        var outputHeight = Double(cropHeight) * scale
        if let maximumWidth, outputWidth > Double(maximumWidth) {
            let shrink = Double(maximumWidth) / outputWidth
            outputWidth *= shrink
            outputHeight *= shrink
        }

        let quantum = max(1, widthQuantum)
        let quantizedWidth = quantize(outputWidth, to: quantum)
        let quantizedHeight = quantize(outputHeight, to: quantum)
        if let maximumPixels,
           quantizedWidth > maximumPixels / quantizedHeight {
            throw Failure.gifFrameTooLarge
        }
        return WindowRecordingFrameGeometry(
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            outputWidth: quantizedWidth,
            outputHeight: quantizedHeight
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
