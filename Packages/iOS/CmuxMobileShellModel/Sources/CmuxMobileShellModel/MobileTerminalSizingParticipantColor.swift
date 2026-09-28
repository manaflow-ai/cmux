public import CmuxTerminalSizing

/// The owner color a viewer uses for one participant of a shared terminal.
///
/// Every viewer derives the same color from the same key, so the border a
/// Mac draws around the grid and the border this phone draws match.
///
/// TODO: Replace with `TerminalSizingParticipantColor` from
/// `Packages/Shared/CmuxTerminalSizing` once it lands. This stand-in must keep
/// the exact rule: FNV-1a 64-bit over the UTF-8 key (`user_id`, else the
/// participant id), then `hash % 10` into ``palette``.
public struct MobileTerminalSizingParticipantColor: Equatable, Hashable, Sendable {
    /// The shared palette, in index order.
    public static let palette: [String] = [
        "#3CC2B0", "#EBA946", "#A688F5", "#5AA9F2", "#F07A8A",
        "#7BC96F", "#E58F4B", "#C77DDB", "#4FC1D9", "#D6C24A",
    ]

    /// The palette index.
    public let index: Int

    /// The `#RRGGBB` hex string.
    public var hex: String { Self.palette[index] }

    /// Red, green and blue components in `0...1`.
    public var rgb: (red: Double, green: Double, blue: Double) {
        let digits = hex.dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Derives the color for a color key.
    /// - Parameter key: The participant's `user_id`, else its participant id.
    public init(key: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        index = Int(hash % UInt64(Self.palette.count))
    }

    /// Derives the color for one participant.
    /// - Parameter participant: The participant; its `user_id` wins over its id.
    public init(participant: TerminalSizingParticipant) {
        self.init(key: participant.userID ?? participant.id)
    }
}
