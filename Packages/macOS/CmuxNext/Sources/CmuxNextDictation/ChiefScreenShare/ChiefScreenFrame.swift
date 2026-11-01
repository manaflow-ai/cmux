public import Foundation

/// One changed screen frame, read on this Mac: its thumbnail signature, its JPEG bytes, the text
/// on it and which window was in front.
public struct ChiefScreenFrame: Sendable, Equatable {
    /// The frame's thumbnail signature, to tell the next frame's change.
    public var signature: VoiceRoomFrameSignature
    /// The frame, downscaled and JPEG-encoded.
    public var jpeg: Data
    /// The frame's text top to bottom, from on-device recognition; empty when it shows none.
    public var text: String
    /// The app in front, nil when unknown.
    public var app: String?
    /// The front window's title, nil when it has none.
    public var window: String?

    /// - Parameters:
    ///   - signature: The frame's thumbnail signature.
    ///   - jpeg: The JPEG bytes.
    ///   - text: The frame's text.
    ///   - app: The app in front.
    ///   - window: The front window's title.
    public init(signature: VoiceRoomFrameSignature, jpeg: Data, text: String, app: String? = nil, window: String? = nil) {
        self.signature = signature
        self.jpeg = jpeg
        self.text = text
        self.app = app
        self.window = window
    }
}
