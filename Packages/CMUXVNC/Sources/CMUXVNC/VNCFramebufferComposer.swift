import Foundation

public struct VNCComposedFrame: Equatable, Sendable {
    public var header: VNCFrameHeader
    public var payload: Data

    public init(header: VNCFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public struct VNCFramebufferComposer: Sendable {
    private var framebuffer = Data()
    private var framebufferWidth = 0
    private var framebufferHeight = 0

    public init() {}

    public var hasFramebuffer: Bool {
        framebufferWidth > 0 && framebufferHeight > 0 && !framebuffer.isEmpty
    }

    public mutating func reset() {
        framebuffer.removeAll(keepingCapacity: false)
        framebufferWidth = 0
        framebufferHeight = 0
    }

    public mutating func apply(header: VNCFrameHeader, payload: Data) -> VNCComposedFrame? {
        guard VNCFrameValidator.validate(header: header, payloadByteCount: payload.count) == nil,
              resizeFramebufferIfNeeded(width: header.framebufferWidth, height: header.framebufferHeight),
              VNCFrameBlitter.copyBGRAFrame(
                  header: header,
                  payload: payload,
                  into: &framebuffer,
                  framebufferWidth: framebufferWidth,
                  framebufferHeight: framebufferHeight
              ) else {
            return nil
        }

        return VNCComposedFrame(
            header: VNCFrameHeader(
                sequence: header.sequence,
                x: 0,
                y: 0,
                width: framebufferWidth,
                height: framebufferHeight,
                framebufferWidth: framebufferWidth,
                framebufferHeight: framebufferHeight,
                stride: framebufferWidth * 4,
                pixelFormat: .bgra8
            ),
            payload: framebuffer
        )
    }

    private mutating func resizeFramebufferIfNeeded(width: Int, height: Int) -> Bool {
        guard let byteCount = Self.framebufferByteCount(width: width, height: height) else {
            return false
        }
        if width == framebufferWidth, height == framebufferHeight, framebuffer.count == byteCount {
            return true
        }
        framebufferWidth = width
        framebufferHeight = height
        framebuffer = Data(repeating: 0, count: byteCount)
        return true
    }

    private static func framebufferByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow else { return nil }
        return byteCount
    }
}
