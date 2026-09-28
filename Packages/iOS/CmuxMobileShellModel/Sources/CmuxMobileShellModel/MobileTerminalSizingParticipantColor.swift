public import CmuxTerminalSizing

/// The owner color a viewer uses for one participant of a shared terminal.
/// It is the shared rule, so the border a Mac draws and the border this phone
/// draws match.
public typealias MobileTerminalSizingParticipantColor = TerminalSizingParticipantColor

extension TerminalSizingParticipantColor {
    /// Red, green and blue components in `0...1`.
    public var rgb: (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
