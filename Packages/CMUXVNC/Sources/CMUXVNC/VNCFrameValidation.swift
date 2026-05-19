import Foundation

public enum VNCFramePixelFormat: UInt32, Codable, Sendable {
    case bgra8 = 1
}

public struct VNCFrameHeader: Equatable, Codable, Sendable {
    public var sequence: UInt64
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var framebufferWidth: Int
    public var framebufferHeight: Int
    public var stride: Int
    public var pixelFormat: VNCFramePixelFormat

    public init(
        sequence: UInt64,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        framebufferWidth: Int,
        framebufferHeight: Int,
        stride: Int,
        pixelFormat: VNCFramePixelFormat = .bgra8
    ) {
        self.sequence = sequence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.framebufferWidth = framebufferWidth
        self.framebufferHeight = framebufferHeight
        self.stride = stride
        self.pixelFormat = pixelFormat
    }

    public var expectedPayloadByteCount: Int? {
        guard width > 0, height > 0, stride > 0 else { return nil }
        let rowBytes = width * 4
        guard rowBytes <= stride else { return nil }
        return rowBytes * height
    }
}

public enum VNCFrameValidationError: Error, Equatable, Sendable {
    case invalidFramebufferSize
    case invalidRect
    case rectOutOfBounds
    case invalidStride
    case payloadTooLarge
    case payloadByteCountMismatch(expected: Int, actual: Int)
    case unsupportedPixelFormat
}

public enum VNCFrameValidator {
    public static func validate(
        header: VNCFrameHeader,
        payloadByteCount: Int,
        maxDimension: Int = 16_384,
        maxPayloadByteCount: Int = 128 * 1024 * 1024
    ) -> VNCFrameValidationError? {
        guard header.framebufferWidth > 0,
              header.framebufferHeight > 0,
              header.framebufferWidth <= maxDimension,
              header.framebufferHeight <= maxDimension else {
            return .invalidFramebufferSize
        }
        guard header.x >= 0,
              header.y >= 0,
              header.width > 0,
              header.height > 0 else {
            return .invalidRect
        }
        guard header.x <= header.framebufferWidth - header.width,
              header.y <= header.framebufferHeight - header.height else {
            return .rectOutOfBounds
        }
        guard header.pixelFormat == .bgra8 else {
            return .unsupportedPixelFormat
        }
        guard header.stride >= header.width * 4 else {
            return .invalidStride
        }
        guard payloadByteCount <= maxPayloadByteCount else {
            return .payloadTooLarge
        }
        guard let expected = header.expectedPayloadByteCount else {
            return .invalidStride
        }
        guard expected == payloadByteCount else {
            return .payloadByteCountMismatch(expected: expected, actual: payloadByteCount)
        }
        return nil
    }
}
