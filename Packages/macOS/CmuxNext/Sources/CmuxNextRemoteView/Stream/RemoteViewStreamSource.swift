public import CoreGraphics
import Foundation

/// The transport-neutral input of the pane. The App adapts a `cmux.rd/1`
/// session (overlay datagrams, the DO relay, or a test) to this; the mock
/// (`MockRemoteStreamSource`) encodes synthetic frames with VideoToolbox.
///
/// Streams must be bounded (`bufferingNewest`): a slow decoder then loses
/// access units, which the pipeline sees as a frame gap and answers with
/// `requestKeyframe()` instead of showing frames that reference lost ones.
public nonisolated protocol RemoteViewStreamSource: AnyObject, Sendable {
    /// Complete access units in frame order. Finishes when the session ends.
    func accessUnits() -> AsyncStream<RemoteAccessUnit>
    /// Path, RTT, loss and session state; the first value arrives at once.
    func statusUpdates() -> AsyncStream<RemoteViewStatus>
    /// Remote cursor position and visibility (view mode overlay, RD6).
    func cursorUpdates() -> AsyncStream<RemoteCursorState>
    /// Asks the host for an IDR: after a decode error or a frame gap.
    func requestKeyframe()
}

/// A source whose pictures arrive already decoded (an RFB compatibility
/// host sends pixels, not video): the pane presents them as they come, with
/// no video decoder. `accessUnits()` stays empty for such a source.
public nonisolated protocol RemoteViewFrameSource: RemoteViewStreamSource {
    /// Pictures in display order, latest wins (bounded `bufferingNewest`).
    /// Finishes when the session ends.
    func decodedFrames() -> AsyncStream<RemoteDecodedFrame>
}

/// The remote cursor as the host reports it, in stream pixels (cap `cursor`:
/// the host leaves it out of the pictures). Shapes ride the control channel;
/// `shapeHash` names one, and `shape` is its image once it arrived.
public nonisolated struct RemoteCursorState: Sendable, Hashable {
    public var position: CGPoint
    public var visible: Bool
    public var shapeHash: UInt64?
    public var shape: RemoteCursorShape?

    public init(position: CGPoint, visible: Bool, shapeHash: UInt64? = nil, shape: RemoteCursorShape? = nil) {
        self.position = position
        self.visible = visible
        self.shapeHash = shapeHash
        self.shape = shape
    }
}

/// One remote cursor shape in stream pixels (`cursor_shape`): the image as large
/// as the remote screen shows it in the stream, and its hotspot from the top left.
/// Equal by id (the host's hash of size, hotspot and pixels).
public nonisolated final class RemoteCursorShape: Sendable, Hashable {
    public let id: UInt32
    public let image: CGImage
    public let pixelSize: CGSize
    public let hotSpot: CGPoint

    public init(id: UInt32, image: CGImage, hotSpot: CGPoint) {
        self.id = id
        self.image = image
        pixelSize = CGSize(width: image.width, height: image.height)
        self.hotSpot = hotSpot
    }

    /// The shape from a `cursor_shape` message: premultiplied RGBA8, rows top first.
    /// Nil when the pixels do not match the size (or the size is out of range).
    public convenience init?(id: UInt32, width: Int, height: Int, hotX: Int, hotY: Int, rgba: Data) {
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height),
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        self.init(id: id, image: image,
                  hotSpot: CGPoint(x: min(max(hotX, 0), width - 1), y: min(max(hotY, 0), height - 1)))
    }

    /// cmux-rd-proto `MAX_CURSOR_SIDE`.
    public static let maxSide = 256

    public static func == (lhs: RemoteCursorShape, rhs: RemoteCursorShape) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
