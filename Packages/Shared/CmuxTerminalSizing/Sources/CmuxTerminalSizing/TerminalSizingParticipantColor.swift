/// The owner color every viewer uses for one participant.
///
/// Macs and iPhones draw the grid border, avatars and size-map outlines in the
/// same color for the same person, so the color is a pure function of a stable
/// key: the participant's `user_id`, or its participant id when no user is
/// known. The key is hashed with 64-bit FNV-1a over its UTF-8 bytes and the
/// hash modulo the palette size picks the color.
///
/// ```swift
/// let hex = TerminalSizingParticipantColor(participant: row.participant).hex
/// ```
public struct TerminalSizingParticipantColor: Hashable, Sendable {
    /// The fixed palette, in index order. Changing it changes every client's colors.
    public static let palette: [String] = [
        "#3CC2B0", "#EBA946", "#A688F5", "#5AA9F2", "#F07A8A",
        "#7BC96F", "#E58F4B", "#C77DDB", "#4FC1D9", "#D6C24A",
    ]

    /// The palette index for the key.
    public let index: Int

    /// The color as `#RRGGBB`.
    public var hex: String { Self.palette[index] }

    /// Picks the color for a raw key.
    ///
    /// - Parameter key: a `user_id`, or a participant id when no user is known.
    public init(key: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        index = Int(hash % UInt64(Self.palette.count))
    }

    /// Picks the color for a participant: its `user_id`, else its id.
    ///
    /// - Parameter participant: the participant to color.
    public init(participant: TerminalSizingParticipant) {
        self.init(key: participant.userID ?? participant.id)
    }
}
