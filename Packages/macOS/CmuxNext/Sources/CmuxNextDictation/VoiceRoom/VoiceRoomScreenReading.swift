/// Reads this Mac's screen for the room: the text it shows, only when it changed.
public protocol VoiceRoomScreenReading: Sendable {
    /// Looks at the screen once.
    ///
    /// - Parameter previous: The last frame's signature, nil at the start.
    /// - Returns: The new frame and its text, or nil when the screen looks the same as `previous`.
    /// - Throws: When the screen cannot be captured (Screen Recording is not allowed).
    /// Runs off the caller's actor: capture and text recognition take tens of milliseconds.
    @concurrent
    func read(changedSince previous: VoiceRoomFrameSignature?) async throws -> VoiceRoomScreenSample?
}

/// One changed screen frame: its signature and the text read from it.
public struct VoiceRoomScreenSample: Equatable, Sendable {
    /// The frame's thumbnail signature.
    public var signature: VoiceRoomFrameSignature
    /// The frame's text, top to bottom, cut to a few hundred characters; empty when it shows none.
    public var text: String

    /// - Parameters:
    ///   - signature: The frame's thumbnail signature.
    ///   - text: The frame's text.
    public init(signature: VoiceRoomFrameSignature, text: String) {
        self.signature = signature
        self.text = text
    }
}
