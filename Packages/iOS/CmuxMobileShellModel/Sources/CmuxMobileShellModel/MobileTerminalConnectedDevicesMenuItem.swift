/// The terminal title menu's "Connected Devices…" item, which opens the size
/// sheet (the same action as the size chip).
///
/// It is offered whenever the Mac published a size state for the terminal,
/// that is, whenever the Mac supports shared sizing, whether or not this
/// device's viewport differs from the grid. The chip shows only on a
/// mismatch, so without this item the sheet would be unreachable while sizes
/// match.
public struct MobileTerminalConnectedDevicesMenuItem: Equatable, Sendable {
    /// Attached participants other than this device.
    public let otherDeviceCount: Int

    /// The item for a terminal's sizing presentation, or `nil` when the Mac
    /// has not published a size state for it.
    /// - Parameter presentation: The terminal's sizing presentation.
    public init?(presentation: MobileTerminalSizingPresentation?) {
        guard let presentation else { return nil }
        otherDeviceCount = presentation.otherParticipants.count
    }
}
