/// Low-rate events of one remote desktop stream (frames come on their own stream).
public enum RemoteDesktopEvent: Hashable, Sendable {
    /// The Mac applied a view; frames encoded for it follow.
    case viewApplied(DesktopView)
    /// The target's size or name changed.
    case target(DesktopTargetInfo)
    case windows([DesktopWindow])
    case modeApplied(mode: DesktopMode, reason: String?)
    /// Text for the phone's pasteboard.
    case clipboard(String)
    case state(DesktopState, reason: String?)
    /// The newest input sequence number the Mac applied.
    case inputApplied(UInt32)
    /// Video started arriving on the datagram lane, or the lane closed.
    case datagramLane(active: Bool)
    /// The Mac ended the session (`desktop.ended`); `closed` follows.
    case ended(reason: String)
    /// The stream ended; last event.
    case closed(reason: String)
}
