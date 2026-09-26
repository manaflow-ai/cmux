/// One character cmux is drawing that the remote has not put on the screen yet.
///
/// Offsets are cells to the right of the live cursor, which is all the host
/// needs: it reads the cursor cell from the surface and advances by the cell
/// width. A confirmed glyph has a negative offset, because the cursor already
/// moved past the echo it is standing in for.
public struct PredictedGlyph: Sendable, Equatable {
    public enum Standing: Sendable, Equatable {
        /// Sent to the remote, no echo yet. Draw it as unconfirmed.
        case speculative
        /// The remote echoed it. Keep drawing until the frame carrying the real
        /// character is on screen, otherwise the cell blanks for one frame.
        case confirmed
    }

    public let character: Character
    public let offset: Int
    public var standing: Standing

    public init(character: Character, offset: Int, standing: Standing) {
        self.character = character
        self.offset = offset
        self.standing = standing
    }
}
