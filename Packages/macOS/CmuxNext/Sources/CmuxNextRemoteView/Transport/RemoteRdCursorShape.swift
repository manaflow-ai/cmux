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
    /// The cap a viewer offers to take frames larger than one FEC block (cmux-rd-core
    /// `caps::FEC_BLOCKS`): the host splits them across interleaved FEC blocks and the Rust
    /// reassembler (`RemoteRdCore`) rebuilds them.
    static let fecBlocksCap = "fec.blocks"
    /// The cap a viewer offers when it shows a picture smaller than the stream scaled up to the
    /// stream's size (welcome `width`/`height`) and keeps sending input in stream pixels: the
    /// host may then encode a smaller picture on a slow link (its resolution ladder).
    static let videoScaledCap = "video.scaled"
    /// The cap a viewer offers when its person turned on Settings > Customize "Sharper Text from
    /// Linux Machines" (`remoteDesktop.sharpLinuxText`, cmux-rd-core `caps::SHARP_TEXT`): a Linux
    /// host whose encoder is OpenH264 codes the session in screen usage instead of camera usage.
    static let sharpTextCap = "video.sharp_text"
    /// The session clock (`caps::CLOCK`): the viewer probes the host's clock, so its
    /// times convert to the host's.
    static let clockCap = "clock"
    /// The stage ledger (`caps::LEDGER`): each frame's host times follow its last shard.
    static let ledgerCap = "ledger"
    /// Long-term reference loss recovery (`caps::LTR`): the viewer acknowledges each decoded
    /// frame's LTR token (`noteDecoded(frame:)`), so a macOS host started with `--ltr 1` repairs
    /// a loss by coding against an acknowledged reference instead of a keyframe. A host without
    /// `--ltr 1` does not offer it back, and the session runs as before.
    static let ltrCap = "video.ltr"
}
