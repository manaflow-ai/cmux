/// One line the room hears from this Mac: a finished sentence from the mic, or the text the
/// screen showed when it changed.
public struct VoiceRoomLine: Equatable, Sendable {
    /// Where a line came from.
    public enum Kind: String, Sendable {
        /// Words said into this Mac's mic, transcribed on device.
        case speech
        /// Text read from this Mac's screen, on device.
        case screen
    }

    /// Where the line came from.
    public var kind: Kind
    /// The words, trimmed.
    public var text: String
    /// The loudest mic level (`0...1`) while it was said; the room keeps the louder of two mics
    /// that heard the same sentence. Zero for screen text.
    public var level: Float

    /// - Parameters:
    ///   - kind: Where the line came from.
    ///   - text: The words.
    ///   - level: The loudest mic level while it was said.
    public init(kind: Kind, text: String, level: Float = 0) {
        self.kind = kind
        self.text = text
        self.level = level
    }
}
