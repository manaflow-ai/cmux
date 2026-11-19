import Foundation

/// Host to viewer with the `cursor` cap: one cursor shape (cmux-rd-proto
/// `Control::CursorShape`), sent once before the first position that names it.
public nonisolated struct RemoteRdCursorShape: Sendable, Equatable, Codable {
    public var shape: UInt32
    public var width: UInt32
    public var height: UInt32
    public var hotX: UInt32
    public var hotY: UInt32
    /// Base64 of `width * height` premultiplied RGBA8 pixels, rows top first.
    public var rgba: String

    public init(shape: UInt32, width: UInt32, height: UInt32, hotX: UInt32, hotY: UInt32, rgba: String) {
        self.shape = shape
        self.width = width
        self.height = height
        self.hotX = hotX
        self.hotY = hotY
        self.rgba = rgba
    }

    enum CodingKeys: String, CodingKey {
        case shape, width, height, rgba
        case hotX = "hot_x"
        case hotY = "hot_y"
    }

    /// The image, or nil when the pixels do not match the size.
    public var cursorShape: RemoteCursorShape? {
        guard let pixels = Data(base64Encoded: rgba) else { return nil }
        return RemoteCursorShape(id: shape, width: Int(width), height: Int(height), hotX: Int(hotX), hotY: Int(hotY), rgba: pixels)
    }
}

public nonisolated extension RemoteRdHello {
    /// The cap a viewer offers when it draws the remote cursor itself (cmux-rd-core
    /// `caps::CURSOR`): the host then leaves the cursor out of its pictures.
    static let cursorCap = "cursor"
    /// The cap a viewer offers when it shows a picture smaller than the stream scaled up to the
    /// stream's size (welcome `width`/`height`) and keeps sending input in stream pixels: the
    /// host may then encode a smaller picture on a slow link (its resolution ladder).
    static let videoScaledCap = "video.scaled"
}
